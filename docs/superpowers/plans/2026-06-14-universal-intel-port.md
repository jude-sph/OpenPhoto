# Universal Intel + Apple Silicon Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship OpenPhoto as a single universal binary (arm64 + x86_64) that runs natively on Apple Silicon and Intel Macs, at the existing macOS 15 floor, with *loud* surfacing whenever a CoreML model can't run on a machine. On the existing Apple Silicon Mac the app runs identically (same arm64 code); the net new capability is the Intel (x86_64) slice.

**Architecture:** One codebase, one `.app`, one Sparkle appcast. No engine/vault/sync/catalog logic changes. The deployment floor stays at macOS 15 (lowering to 14 was rejected — see Task 1). CoreML loaders gain a compute-units retry ladder (for Intel's missing Neural Engine) and report a per-model availability status into a new Core registry; the App observes it and shows a prominent banner + explicit unavailable states on the People and Search screens. These additions are inert when models load fine (i.e. on the Apple Silicon Mac). Release packaging builds both arches and refuses to ship a non-universal binary.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI (`@Observable`), CoreML, swift-testing (`import Testing`), GRDB, Sparkle, bash packaging scripts.

**Reference spec:** `docs/superpowers/specs/2026-06-14-universal-intel-port-design.md`

---

## File structure

| File | Responsibility | New/Modify |
|---|---|---|
| `Package.swift` | **No change** — floor stays `.macOS(.v15)` (see Task 1) | — |
| `Sources/OpenPhotoCore/Derivation/MLAvailability.swift` | Thread-safe per-model availability registry + pure capability mapping + model keys + compute-units retry ladder | **Create** |
| `Sources/OpenPhotoCore/Derivation/EmbedStage.swift` | Report MobileCLIP image/text availability; load via ladder | Modify |
| `Sources/OpenPhotoCore/Faces/FaceEmbedder.swift` | Report AdaFace availability; load via ladder | Modify |
| `Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift` | Unit tests for registry, capability mapping, EmbedStage reporting | **Create** |
| `Sources/OpenPhotoApp/AppState.swift` | Observe `MLAvailability.didChange`; expose `mlStatus` / `mlUnavailable` | Modify |
| `Sources/OpenPhotoApp/MLUnavailableBanner.swift` | Loud red top banner for any unavailable capability | **Create** |
| `Sources/OpenPhotoApp/OpenPhotoApp.swift` | Mount the banner in `RootView` | Modify |
| `Sources/OpenPhotoApp/People/PeopleView.swift` | Explicit "face recognition unavailable" state | Modify |
| `Sources/OpenPhotoApp/Search/SearchView.swift` | Explicit "semantic search unavailable" state | Modify |
| `scripts/make-app.sh` | Universal build, universal product paths, `lipo` gate (plist min-system stays 15.0) | Modify |
| `docs/RELEASING.md`, `README.md` | Universal build + requirements | Modify |
| `.github/workflows/*` (if present) | Universal build command in CI | Modify |

---

### Task 1: Deployment floor — RESOLVED: stays macOS 15 (no change)

**Outcome:** Floor remains `.macOS(.v15)`. Lowering to `.v14` was attempted and reverted: it forced
`#available(macOS 15, *)` guards on three macOS-15-only APIs already in the app —
`ScrollPosition`/`onScrollGeometryChange` (`SelectionUI.swift`), `pointerStyle` (`InspectorView.swift`),
and `AVAssetExportSession.export(to:as:)` (`VideoMetadataEmbedder.swift`) — each needing a macOS-14
fallback. That's permanent complexity (every future macOS-15 API would need the same) plus minor
macOS-14 feature regressions, for **no in-scope benefit**: the i9 runs Tahoe 26 and the other Macs are
Apple Silicon on current macOS — none run macOS 14. Jude confirmed macOS 15 is a fine floor.

**No files change in this task.** `Package.swift` keeps `platforms: [.macOS(.v15)]`. `ContentUnavailableView`,
`@Observable`, `Grid`, etc. used by later tasks are macOS-14 APIs and remain valid at the macOS 15 floor.

---

### Task 2: Core — ML availability registry + capability mapping (TDD)

A new Core file holds: model-key constants, the `MLStatus`/`MLCapability` types, a thread-safe `MLAvailability` registry that posts a notification on change, a pure `mlCapabilityStatus(_:from:)` mapping, and an internal `MLLoader` compute-units ladder.

**Files:**
- Create: `Sources/OpenPhotoCore/Derivation/MLAvailability.swift`
- Create: `Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func registryReportsAndDedupesChanges() {
    let reg = MLAvailability()
    #expect(reg.status(model: "x") == .unknown)
    #expect(reg.report(model: "x", .available) == true)    // changed
    #expect(reg.report(model: "x", .available) == false)   // no change → no post
    #expect(reg.status(model: "x") == .available)
    #expect(reg.report(model: "x", .unavailable("boom")) == true)
    #expect(reg.snapshot()["x"] == .unavailable("boom"))
}

@Test func registryPostsNotificationOnChangeOnly() {
    let reg = MLAvailability()
    var posts = 0
    let token = NotificationCenter.default.addObserver(
        forName: MLAvailability.didChange, object: nil, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    reg.report(model: "y", .available)     // post
    reg.report(model: "y", .available)     // no post
    reg.report(model: "y", .absent)        // post
    #expect(posts == 2)
}

@Test func capabilityUnknownWhenNothingTried() {
    #expect(mlCapabilityStatus(.faceRecognition, from: [:]) == .unknown)
    #expect(mlCapabilityStatus(.semanticSearch, from: [:]) == .unknown)
}

@Test func faceRecognitionTracksAdaface() {
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .available]) == .available)
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .unavailable("no")]) == .unavailable("no"))
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .absent]) == .absent)
}

@Test func semanticSearchUnavailableIfEitherModelFails() {
    // Image failed, text not yet tried → loud unavailable wins.
    let m: [String: MLStatus] = [MLModelKey.mobileclipImage: .unavailable("boom"),
                                 MLModelKey.mobileclipText: .unknown]
    if case .unavailable = mlCapabilityStatus(.semanticSearch, from: m) {} else {
        Issue.record("expected .unavailable when the image model fails")
    }
    // Both available → available.
    #expect(mlCapabilityStatus(.semanticSearch,
        from: [MLModelKey.mobileclipImage: .available,
               MLModelKey.mobileclipText: .available]) == .available)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter registryReportsAndDedupesChanges 2>&1 | tail -15`
Expected: FAIL to compile — `cannot find 'MLAvailability' in scope` (and the other new symbols).

- [ ] **Step 3: Create the implementation**

Create `Sources/OpenPhotoCore/Derivation/MLAvailability.swift`:

```swift
import Foundation
import CoreML

/// Stable keys for the three on-device CoreML models, used by the availability registry.
public enum MLModelKey {
    public static let adaface = "adaface_ir101"
    public static let mobileclipImage = "mobileclip_s2_image"
    public static let mobileclipText = "mobileclip_s2_text"
}

/// Per-model load outcome on *this* machine.
/// - `.absent` is a legitimate degraded mode (model package not installed) — NOT surfaced loudly.
/// - `.unavailable` means the model is present but failed to compile/load/run here — surfaced loudly.
public enum MLStatus: Sendable, Equatable {
    case unknown
    case available
    case absent
    case unavailable(String)
}

/// User-facing ML capabilities (a capability may require more than one model).
public enum MLCapability: String, CaseIterable, Sendable {
    case faceRecognition
    case semanticSearch
}

/// Thread-safe registry of per-model `MLStatus`. CoreML loads happen off the main actor, so this is
/// lock-guarded. Posts `MLAvailability.didChange` on any status transition (deduped) so the App can
/// react. A process-wide `.shared` instance is what the loaders report into; tests use fresh instances.
public final class MLAvailability: @unchecked Sendable {
    public static let shared = MLAvailability()
    public static let didChange = Notification.Name("OpenPhotoMLAvailabilityDidChange")

    private let lock = NSLock()
    private var byModel: [String: MLStatus] = [:]

    public init() {}

    /// Record `status` for `model`. Returns true (and posts `didChange`) only if it changed.
    @discardableResult
    public func report(model: String, _ status: MLStatus) -> Bool {
        lock.lock()
        let changed = byModel[model] != status
        byModel[model] = status
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return changed
    }

    public func status(model: String) -> MLStatus {
        lock.lock(); defer { lock.unlock() }
        return byModel[model] ?? .unknown
    }

    public func snapshot() -> [String: MLStatus] {
        lock.lock(); defer { lock.unlock() }
        return byModel
    }
}

/// Pure mapping from raw per-model statuses to a capability status.
/// Precedence: any required model `.unavailable` → `.unavailable` (loudest); else any `.absent` →
/// `.absent`; else any `.unknown` → `.unknown`; else `.available`.
public func mlCapabilityStatus(_ capability: MLCapability,
                               from byModel: [String: MLStatus]) -> MLStatus {
    let keys: [String]
    switch capability {
    case .faceRecognition: keys = [MLModelKey.adaface]
    case .semanticSearch:  keys = [MLModelKey.mobileclipImage, MLModelKey.mobileclipText]
    }
    let statuses = keys.map { byModel[$0] ?? .unknown }
    for s in statuses { if case .unavailable = s { return s } }
    if statuses.contains(.absent) { return .absent }
    if statuses.contains(.unknown) { return .unknown }
    return .available
}

/// Loads a *compiled* CoreML model, walking down the compute-units ladder so an Intel Mac (which has
/// no Neural Engine) still loads via GPU or, failing that, CPU. Throws the last error if all fail.
enum MLLoader {
    static func load(compiledModelAt url: URL) throws -> MLModel {
        let ladder: [MLComputeUnits] = [.all, .cpuAndGPU, .cpuOnly]
        var lastError: Swift.Error?
        for units in ladder {
            let config = MLModelConfiguration()
            config.computeUnits = units
            do { return try MLModel(contentsOf: url, configuration: config) }
            catch { lastError = error }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MLAvailability 2>&1 | tail -15`
Expected: the 5 new tests PASS. (`--filter MLAvailability` matches the file/suite and the symbol-named tests.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Derivation/MLAvailability.swift Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift
git commit -m "feat(core): ML availability registry + capability mapping + compute-units ladder"
```

---

### Task 3: Core — loaders report availability and load via the ladder (TDD)

Wire `EmbedStage` and `FaceEmbedder` to (a) load compiled models through `MLLoader.load` and (b) report `.absent` / `.unavailable` / `.available` into a registry. `EmbedStage` gains an injectable registry so it's unit-testable; `FaceEmbedder` reports into `.shared` (singleton, smoke-covered).

**Files:**
- Modify: `Sources/OpenPhotoCore/Derivation/EmbedStage.swift`
- Modify: `Sources/OpenPhotoCore/Faces/FaceEmbedder.swift`
- Modify: `Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift`

- [ ] **Step 1: Write the failing tests** (append to `MLAvailabilityTests.swift`)

```swift
@Test func embedStageReportsAbsentWhenModelMissing() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ml-absent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let reg = MLAvailability()
    let stage = EmbedStage(modelDirectory: tmp, availability: reg)
    #expect(stage.embedImage(at: tmp.appendingPathComponent("nope.jpg")) == nil)
    #expect(reg.status(model: MLModelKey.mobileclipImage) == .absent)
}

@Test func embedStageReportsUnavailableWhenModelBroken() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ml-broken-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // A present-but-invalid model package: compileModel will throw → loud .unavailable.
    try Data("not a real model".utf8)
        .write(to: tmp.appendingPathComponent("mobileclip_s2_image.mlpackage"))

    let reg = MLAvailability()
    let stage = EmbedStage(modelDirectory: tmp, availability: reg)
    #expect(stage.embedImage(at: tmp.appendingPathComponent("nope.jpg")) == nil)
    if case .unavailable = reg.status(model: MLModelKey.mobileclipImage) {} else {
        Issue.record("expected .unavailable for a present-but-broken model")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter embedStageReportsAbsentWhenModelMissing 2>&1 | tail -15`
Expected: FAIL to compile — `extra argument 'availability' in call` (the init doesn't take it yet).

- [ ] **Step 3: Update `EmbedStage`**

In `Sources/OpenPhotoCore/Derivation/EmbedStage.swift`:

Add a stored registry and accept it in `init` (replace the existing property block around lines 29-30 and the `init` at lines 44-46):

```swift
    private let modelDirectory: URL?
    private let availability: MLAvailability
    private let lock = NSLock()
```

```swift
    public init(modelDirectory: URL? = nil, availability: MLAvailability = .shared) {
        self.modelDirectory = modelDirectory ?? Bundle.main.resourceURL
        self.availability = availability
    }
```

Change the two load call-sites to pass a model key (lines ~90 and ~99):

```swift
            imageModel = compileAndLoad(
                modelDirectory?.appendingPathComponent("mobileclip_s2_image.mlpackage"),
                key: MLModelKey.mobileclipImage)
```

```swift
            textModel = compileAndLoad(
                modelDirectory?.appendingPathComponent("mobileclip_s2_text.mlpackage"),
                key: MLModelKey.mobileclipText)
```

Replace the `static func compileAndLoad` (lines ~115-125) with an instance method that loads via the ladder and reports:

```swift
    private func compileAndLoad(_ url: URL?, key: String) -> MLModel? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            availability.report(model: key, .absent)
            return nil
        }
        do {
            let compiled = try MLModel.compileModel(at: url)
            let model = try MLLoader.load(compiledModelAt: compiled)
            availability.report(model: key, .available)
            return model
        } catch {
            availability.report(model: key, .unavailable(error.localizedDescription))
            return nil
        }
    }
```

(`compileAndLoad` is now an instance method — it was `static` and called as `Self.compileAndLoad`; the call-sites above already drop the `Self.` prefix.)

- [ ] **Step 4: Update `FaceEmbedder`**

In `Sources/OpenPhotoCore/Faces/FaceEmbedder.swift`, replace `loadedModel()` (lines ~51-64) so it loads via the ladder and reports into `.shared`:

```swift
    private func loadedModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        do {
            let url = try compiledModelURL()
            let m = try MLLoader.load(compiledModelAt: url)
            model = m
            MLAvailability.shared.report(model: MLModelKey.adaface, .available)
            return m
        } catch Error.resourceMissing {
            MLAvailability.shared.report(model: MLModelKey.adaface, .absent)
            return nil
        } catch {
            MLAvailability.shared.report(model: MLModelKey.adaface, .unavailable(error.localizedDescription))
            return nil
        }
    }
```

- [ ] **Step 5: Run the new tests + full suite**

Run: `swift test --filter MLAvailability 2>&1 | tail -15`
Expected: the 2 new EmbedStage tests PASS (plus the Task-2 tests).
Run: `swift test 2>&1 | tail -15`
Expected: whole suite green (no regressions in existing embed/face tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Derivation/EmbedStage.swift Sources/OpenPhotoCore/Faces/FaceEmbedder.swift Tests/OpenPhotoCoreTests/MLAvailabilityTests.swift
git commit -m "feat(core): loaders report availability and load via compute-units ladder"
```

---

### Task 4: App — AppState observes ML availability

`AppState` subscribes to `MLAvailability.didChange`, recomputes per-capability status on the main actor, and exposes `mlStatus` (observable) + a `mlUnavailable` convenience. App layer = build-and-smoke (no unit test target for App).

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add observable state + refresh + subscription**

In `Sources/OpenPhotoApp/AppState.swift`, add these properties near the other `var` declarations (e.g. just after `var refreshToken = 0` around line 81):

```swift
    /// Per-capability ML availability on this Mac, mirrored from `MLAvailability` (Core). Drives the
    /// loud unavailable banner + the People/Search unavailable states. Empty until the first model
    /// load is attempted.
    var mlStatus: [MLCapability: MLStatus] = [:]

    /// Capabilities that are present-but-broken on this machine (the loud cases only — never `.absent`).
    var mlUnavailable: [(capability: MLCapability, reason: String)] {
        MLCapability.allCases.compactMap { cap in
            if case .unavailable(let reason) = (mlStatus[cap] ?? .unknown) { return (cap, reason) }
            return nil
        }
    }
```

Add a refresh method (place it in the same file, alongside other `func`s):

```swift
    /// Recompute `mlStatus` from the Core registry snapshot. Called on init and on every
    /// `MLAvailability.didChange`.
    func refreshMLStatus() {
        let snap = MLAvailability.shared.snapshot()
        var next: [MLCapability: MLStatus] = [:]
        for cap in MLCapability.allCases { next[cap] = mlCapabilityStatus(cap, from: snap) }
        mlStatus = next
    }
```

- [ ] **Step 2: Subscribe in `init`**

Find `AppState`'s `init` (it's `@Observable @MainActor final class AppState`). Add at the end of `init`:

```swift
        refreshMLStatus()
        NotificationCenter.default.addObserver(
            forName: MLAvailability.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMLStatus() }
        }
```

(If `AppState` has no explicit `init`, add one: `init() { refreshMLStatus(); NotificationCenter.default.addObserver(...) }`. The observer lives for the app's lifetime — no removal needed; `[weak self]` avoids the cycle. `MainActor.assumeIsolated` is safe here because `queue: .main` runs the block on the main thread — same pattern as `OpenPhotoApp.swift`'s command handlers.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -15`
Expected: **Build complete**.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): AppState mirrors ML availability from the Core registry"
```

---

### Task 5: App — loud banner + People/Search unavailable states

A prominent red banner at the top of the main window for any unavailable capability, plus explicit unavailable states on the two affected screens so neither ever silently shows an empty result.

**Files:**
- Create: `Sources/OpenPhotoApp/MLUnavailableBanner.swift`
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift:70-104` (mount in `RootView`)
- Modify: `Sources/OpenPhotoApp/People/PeopleView.swift`
- Modify: `Sources/OpenPhotoApp/Search/SearchView.swift`

- [ ] **Step 1: Create the banner + capability display names**

Create `Sources/OpenPhotoApp/MLUnavailableBanner.swift`:

```swift
import SwiftUI
import OpenPhotoCore

extension MLCapability {
    var displayName: String {
        switch self {
        case .faceRecognition: return "Face recognition"
        case .semanticSearch:  return "Semantic search"
        }
    }
}

/// Loud, persistent banner shown at the top of the main window whenever a CoreML capability is
/// present-but-broken on this Mac. Renders nothing when everything is fine (or merely `.absent`).
struct MLUnavailableBanner: View {
    @Bindable var state: AppState

    var body: some View {
        let items = state.mlUnavailable
        if !items.isEmpty {
            VStack(spacing: 4) {
                ForEach(items, id: \.capability) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(item.capability.displayName) is unavailable on this Mac — the model couldn’t be loaded.")
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .help(item.reason)   // full error on hover
                }
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.92))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

- [ ] **Step 2: Mount the banner in `RootView`**

In `Sources/OpenPhotoApp/OpenPhotoApp.swift`, the loaded branch is a `ZStack` (lines ~70-104). Add the banner as a top-aligned overlay on that `ZStack`. Change the closing of the `ZStack` (after the `.task(id:)` modifier at line ~113) to also carry:

```swift
            .overlay(alignment: .top) { MLUnavailableBanner(state: state) }
            .animation(.easeOut(duration: 0.2), value: state.mlUnavailable.count)
```

(Place these two modifiers on the same `ZStack` that already has `.background(...)` and `.task(...)`. The banner floats over the very top of the window — deliberately hard to miss.)

- [ ] **Step 3: People screen unavailable state**

In `Sources/OpenPhotoApp/People/PeopleView.swift`, wrap the existing `var body` content so face-recognition failure replaces the grid. Change:

```swift
    var body: some View {
        // …existing content…
    }
```

to:

```swift
    var body: some View {
        if case .unavailable = (state.mlStatus[.faceRecognition] ?? .unknown) {
            ContentUnavailableView {
                Label("Face recognition unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("The face model couldn’t be loaded on this Mac, so people can’t be detected or grouped here.")
            }
        } else {
            // …existing content moved here verbatim…
        }
    }
```

(Move the screen's current `body` contents into the `else` branch unchanged. `ContentUnavailableView` is macOS 14 — fine at our floor.)

- [ ] **Step 4: Search screen unavailable state**

In `Sources/OpenPhotoApp/Search/SearchView.swift`, apply the same wrap, but only for the **semantic** search mode (keyword/EXIF search does not need the model). Use the existing `state.searchMode` (an enum on `AppState`). At the top of `var body`:

```swift
    var body: some View {
        if state.searchMode == .semantic,
           case .unavailable = (state.mlStatus[.semanticSearch] ?? .unknown) {
            ContentUnavailableView {
                Label("Semantic search unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("The semantic-search model couldn’t be loaded on this Mac. Keyword and filter search still work.")
            }
        } else {
            // …existing content moved here verbatim…
        }
    }
```

(If `SearchMode`'s semantic case is named differently than `.semantic`, match the actual case name — check the `enum SearchMode` definition referenced by `AppState.searchMode`.)

- [ ] **Step 5: Build + manual smoke**

Run: `swift build 2>&1 | tail -15`
Expected: **Build complete**.

Smoke (loud-path proof without real failure): temporarily make `AppState.refreshMLStatus()` seed a fake failure — add `next[.faceRecognition] = .unavailable("smoke test")` before `mlStatus = next`, run `swift run OpenPhotoApp`, confirm the red banner appears at the window top and the People screen shows the unavailable state. **Then remove the fake line** and rebuild. (Do not commit the fake.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/MLUnavailableBanner.swift Sources/OpenPhotoApp/OpenPhotoApp.swift Sources/OpenPhotoApp/People/PeopleView.swift Sources/OpenPhotoApp/Search/SearchView.swift
git commit -m "feat(app): loud banner + People/Search unavailable states for broken ML"
```

---

### Task 6: Packaging — universal `make-app.sh` + `lipo` gate

Build both arches, read products from the universal output dir, refuse to ship a single-arch binary, and set the bundle's min-system to 14.

**Files:**
- Modify: `scripts/make-app.sh`

- [ ] **Step 1: Build both arches**

In `scripts/make-app.sh`, change line 6:

```bash
swift build -c release
```

to:

```bash
swift build -c release --arch arm64 --arch x86_64
```

- [ ] **Step 2: Copy the universal binary + assert it is universal**

Replace line 19:

```bash
cp .build/release/OpenPhotoApp "$APP/Contents/MacOS/OpenPhoto"
```

with (the universal build lands under `.build/apple/Products/Release/`):

```bash
cp .build/apple/Products/Release/OpenPhotoApp "$APP/Contents/MacOS/OpenPhoto"

# Refuse to ship a non-universal binary (e.g. someone dropped the --arch flags or built host-only).
ARCHS="$(lipo -archs "$APP/Contents/MacOS/OpenPhoto" 2>/dev/null || true)"
if [[ "$ARCHS" != *x86_64* || "$ARCHS" != *arm64* ]]; then
  echo "error: OpenPhoto binary is not universal (got '$ARCHS', want 'x86_64 arm64')." >&2
  echo "       Build with: swift build -c release --arch arm64 --arch x86_64" >&2
  exit 1
fi
echo "Universal binary OK: $ARCHS"
```

- [ ] **Step 3: Leave the bundle min-system at 15.0 (no change)**

The floor stays macOS 15, so `LSMinimumSystemVersion` in the Info.plist heredoc remains `15.0` — do
**not** change it. (This step is a no-op, kept here so the step numbering matches the original plan.)

- [ ] **Step 4: Point the Sparkle.framework copy at the universal products dir**

Replace lines 116-117:

```bash
SPARKLE_FW="$(find .build -path '*/release/Sparkle.framework' -type d | head -1)"
[[ -n "$SPARKLE_FW" ]] || SPARKLE_FW="$(find .build -name 'Sparkle.framework' -type d | head -1)"
```

with (prefer the universal products dir; keep a find fallback):

```bash
SPARKLE_FW=".build/apple/Products/Release/Sparkle.framework"
[[ -d "$SPARKLE_FW" ]] || SPARKLE_FW="$(find .build -path '*/release/Sparkle.framework' -type d | head -1)"
[[ -n "$SPARKLE_FW" && -d "$SPARKLE_FW" ]] || SPARKLE_FW="$(find .build -name 'Sparkle.framework' -type d | head -1)"
```

- [ ] **Step 5: Build the bundle + verify universality end-to-end**

Run: `./scripts/make-app.sh 2>&1 | tail -25`
Expected: prints `Universal binary OK: x86_64 arm64` (order may vary) and `Built build/OpenPhoto.app`, no errors.
Run: `lipo -archs build/OpenPhoto.app/Contents/MacOS/OpenPhoto`
Expected: `x86_64 arm64`.
Run: `lipo -archs build/OpenPhoto.app/Contents/Frameworks/Sparkle.framework/Sparkle`
Expected: `x86_64 arm64` (Sparkle is already a universal binary target).

- [ ] **Step 6: Commit**

```bash
git add scripts/make-app.sh
git commit -m "build: universal (arm64+x86_64) app bundle with a lipo safety gate; min-system 14"
```

---

### Task 7: Spike — Rosetta x86_64 smoke (local) + record findings

The agent can validate the Intel **code path** locally by running the x86_64 slice under Rosetta. This is an early-warning signal (Rosetta does not perfectly mirror native-Intel CoreML), not the final acceptance — that's Task 9 on the i9.

**Files:**
- Create: `docs/superpowers/plans/2026-06-14-universal-intel-port-SPIKE-NOTES.md`

- [ ] **Step 1: Ensure Rosetta is available**

Run: `/usr/bin/pgrep -q oahd && echo present || softwareupdate --install-rosetta --agree-to-license`
Expected: `present`, or Rosetta installs.

- [ ] **Step 2: Launch the Intel slice under Rosetta**

Run: `arch -x86_64 build/OpenPhoto.app/Contents/MacOS/OpenPhoto`
Expected: the app launches (it will run as a translated x86_64 process). Open a library, scroll the timeline, open the People screen, run a semantic search.

- [ ] **Step 3: Record findings**

Create `docs/superpowers/plans/2026-06-14-universal-intel-port-SPIKE-NOTES.md` capturing, in prose:
- Did the x86_64 process launch and browse/import cleanly?
- Did **face recognition** produce clusters, or did the banner show `.unavailable`? Copy the banner's hover reason if shown.
- Did **semantic search** return results, or surface unavailable?
- Which compute-units rung actually loaded each model, if determinable (add a temporary `print` in `MLLoader.load` logging `units` on success, observe, then remove it).
- Verdict: is the compute-units ladder sufficient, or did a model fail outright under Rosetta?

(Caveat to note in the doc: a failure *under Rosetta* does not necessarily mean failure on native Intel, and vice-versa — Task 9 is authoritative.)

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-06-14-universal-intel-port-SPIKE-NOTES.md
git commit -m "docs: Rosetta x86_64 spike findings for the universal port"
```

---

### Task 8: CI + docs

**Files:**
- Modify: `.github/workflows/*.yml` (if present)
- Modify: `docs/RELEASING.md`
- Modify: `README.md`

- [ ] **Step 1: Update CI build command (if a workflow exists)**

Run: `ls .github/workflows/ 2>/dev/null && grep -rn "swift build" .github/workflows/ 2>/dev/null`
If a workflow runs `swift build -c release`, change it to `swift build -c release --arch arm64 --arch x86_64`. If there is no workflow file (release is local via `scripts/`), skip — the universal flags live in `make-app.sh` already.

- [ ] **Step 2: Document the universal build in RELEASING.md**

In `docs/RELEASING.md`, add a short subsection near the build/packaging steps:

```markdown
### Universal binary (Intel + Apple Silicon)

`make-app.sh` builds both slices via `swift build -c release --arch arm64 --arch x86_64` and reads
products from `.build/apple/Products/Release/`. It refuses to package unless the binary is universal:

    lipo -archs build/OpenPhoto.app/Contents/MacOS/OpenPhoto   # → x86_64 arm64

Deployment floor is macOS 15 (`LSMinimumSystemVersion` 15.0 + `Package.swift` `.macOS(.v15)`).
On Intel there is no Neural Engine; the CoreML loaders fall back GPU→CPU automatically and surface a
loud in-app banner if a model still can't load.
```

- [ ] **Step 3: Update README requirements**

In `README.md`, update the requirements/system line to state: **macOS 15 (Sequoia) or later, on Apple Silicon or Intel Macs (universal binary).** (Replace any existing "Apple Silicon"-only wording; keep the macOS 15 version.)

- [ ] **Step 4: Commit**

```bash
git add docs/RELEASING.md README.md .github/workflows 2>/dev/null; git add docs/RELEASING.md README.md
git commit -m "docs: universal build + macOS 15 / Intel requirements"
```

---

### Task 9: Final acceptance on the i9 Tahoe Mac (manual handoff — Jude)

Not an agent task. After the branch is built, hand Jude the universal `.app` (or a notarization-free local copy) to run **natively** on the i9 Tahoe Mac.

- [ ] Copy `build/OpenPhoto.app` to the i9 Tahoe Mac and launch it (native x86_64 — confirm via Activity Monitor "Kind: Intel").
- [ ] Library opens; timeline browse + scroll smooth; import a small batch.
- [ ] **Face recognition** produces correct clusters (no loud banner). If the banner shows, capture the reason — that's the spike's worst case and we decide whether to ship faces-disabled on Intel.
- [ ] **Semantic search** returns expected results for a known query.
- [ ] **Sparkle self-update** sees the appcast and installs the universal archive.
- [ ] Note ML indexing time + memory on Intel (informational — sets expectations, not a blocker).

---

## Self-review

**Spec coverage:**
- Universal binary (arm64+x86_64) → Task 6. ✓
- macOS 15 floor (unchanged) → Task 1 (decision/no-op) + Task 6 (plist stays 15.0). ✓
- Monterey out of scope → no backport tasks. ✓
- Zero logic/UI rewrite → only additive ML-availability surfacing + build changes. ✓
- CoreML-on-Intel compute-units fallback → Task 2 (`MLLoader` ladder) + Task 3 (loaders use it). ✓
- Loud ML-unavailable (banner + explicit feature states, never silent/blank) → Tasks 4-5. ✓
- `.absent` stays a quiet degraded mode; only `.unavailable` is loud → `mlUnavailable` filters to `.unavailable`. ✓
- Spike: universal build + Rosetta + i9 acceptance → Tasks 6-7-9. ✓
- Sparkle universal (no work) → verified in Task 6 Step 5. ✓
- Docs (RELEASING, README), CI → Task 8. ✓
- On-disk format unchanged → no `docs/format/` task (correct; spec says unaffected). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `MLStatus`, `MLCapability`, `MLModelKey.{adaface,mobileclipImage,mobileclipText}`, `MLAvailability.{shared,didChange,report,status,snapshot}`, `mlCapabilityStatus(_:from:)`, `MLLoader.load(compiledModelAt:)`, `EmbedStage(modelDirectory:availability:)`, `AppState.{mlStatus,mlUnavailable,refreshMLStatus}`, `MLCapability.displayName` — names used identically across Tasks 2-5. ✓
