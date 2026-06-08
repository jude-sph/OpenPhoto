# Library Selection & Evict (Stage A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Select mode to the timeline and folder views (the import screen's selection UX, shared) with a bulk Evict-to-bin action guarded by an "only copy" warning.

**Architecture:** Pure selection + presence logic lives in `OpenPhotoCore` (the only test target) and is unit-tested; SwiftUI wiring lives in `OpenPhotoApp` and is build-and-smoke verified. Eviction reuses the existing `BinStore` (vault-format §8) via a new batch `LibraryService.evict`. The "only copy" warning derives from the existing `imports.jsonl` registry — the honest Stage-A presence signal.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (Command Line Tools — no Xcode), Swift Testing, GRDB.

**Spec:** `docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md` (Stage A, §11). Stages B (Send) and C (Locations) get their own plans afterward.

---

## Conventions for every task

- **Build:** `swift build` must succeed with **zero warnings**.
- **Test (specific):** `swift test --filter <testFunctionName>`
- **Test (full suite):** `swift test` — must stay green (71 tests today).
- **Run the app (smoke):** `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
- **Never** touch real user folders. All fixtures are generated mock files in temp dirs (`TestDirs`, `makeJPEG`).
- **Commit** at the end of each task with the given message (it already includes the required trailer).
- TDD for Core tasks (1–4): write the failing test, see it fail, implement, see it pass. App tasks (5–9) are implement → build (0 warnings) → manual smoke → commit.

## File structure (what each new/changed file is responsible for)

**Create (Core, tested):**
- `Sources/OpenPhotoCore/Selection/SelectionModel.swift` — pure, UI-agnostic selection state (set, anchor, range, rubber-band hit-testing, live-pair-partner expansion). One implementation, used by all three grids.
- `Sources/OpenPhotoCore/Presence/BackupProbe.swift` — Stage-A "is this hash known anywhere but this Mac?" from `imports.jsonl`.
- `Tests/OpenPhotoCoreTests/SelectionModelTests.swift`, `Tests/OpenPhotoCoreTests/BackupProbeTests.swift`.

**Create (App, smoke):**
- `Sources/OpenPhotoApp/Selection/SelectionUI.swift` — shared SwiftUI: `CellFramesKey`, `.cellFrame`, `.selectionChrome`, `RubberBandModifier`, `SelectionActionBar`, `evictAlertMessage`.

**Modify:**
- `Sources/OpenPhotoCore/Import/ImportRegistry.swift` — add `deviceKeys(forHash:)` + hash index.
- `Sources/OpenPhotoCore/LibraryService.swift` — add batch `evict(_:)`.
- `Sources/OpenPhotoApp/AppState.swift` — add `onlyCopyCount(_:)` and `evict(_:)`.
- `Sources/OpenPhotoApp/Timeline/TimelineView.swift` — Select mode.
- `Sources/OpenPhotoApp/Folders/FolderGridView.swift` — Select mode.
- `Sources/OpenPhotoApp/Devices/ImportView.swift` — adopt the shared `SelectionModel` (DRY consolidation).

---

## Task 1: SelectionModel (pure selection logic)

**Files:**
- Create: `Sources/OpenPhotoCore/Selection/SelectionModel.swift`
- Test: `Tests/OpenPhotoCoreTests/SelectionModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/SelectionModelTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

private func items(_ ids: String...) -> [SelectableItem] { ids.map { SelectableItem(id: $0) } }

@Test func toggleAddsAndRemoves() {
    var s = SelectionModel()
    s.toggle(SelectableItem(id: "a"))
    #expect(s.contains("a") && s.count == 1)
    s.toggle(SelectableItem(id: "a"))
    #expect(!s.contains("a") && s.count == 0)
}

@Test func toggleMirrorsLivePartner() {
    var s = SelectionModel()
    s.toggle(SelectableItem(id: "photo", partnerID: "video"))
    #expect(s.contains("photo") && s.contains("video"))
    s.toggle(SelectableItem(id: "photo", partnerID: "video"))
    #expect(!s.contains("photo") && !s.contains("video"))
}

@Test func tapSetsAnchorAndToggles() {
    var s = SelectionModel()
    let list = items("a", "b", "c", "d")
    s.tap(index: 1, items: list, extendingRange: false)
    #expect(s.contains("b") && s.anchor == 1)
}

@Test func shiftTapSelectsInclusiveRange() {
    var s = SelectionModel()
    let list = items("a", "b", "c", "d")
    s.tap(index: 1, items: list, extendingRange: false)   // anchor at b
    s.tap(index: 3, items: list, extendingRange: true)    // range b…d
    #expect(s.contains("b") && s.contains("c") && s.contains("d") && !s.contains("a"))
}

@Test func selectAllAddsEveryItemWithPartners() {
    var s = SelectionModel()
    s.selectAll([SelectableItem(id: "p", partnerID: "v"), SelectableItem(id: "q")])
    #expect(s.contains("p") && s.contains("v") && s.contains("q") && s.count == 3)
}

@Test func dragSelectsIntersectingCellsFromBase() {
    var s = SelectionModel()
    let list = items("a", "b", "c")
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 10, height: 10),
        "b": CGRect(x: 20, y: 0, width: 10, height: 10),
        "c": CGRect(x: 40, y: 0, width: 10, height: 10),
    ]
    s.toggle(SelectableItem(id: "c"))     // pre-existing selection survives the drag
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 25, height: 10), frames: frames, items: list)
    #expect(s.contains("a") && s.contains("b") && s.contains("c") && !s.contains("c") == false)
    s.endDrag()
    // A fresh drag starts from the current selection, not the stale base.
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 100, y: 100, width: 1, height: 1), frames: frames, items: list)
    #expect(s.contains("a") && s.contains("b") && s.contains("c"))
}

@Test func clearEmptiesSelectionAndAnchor() {
    var s = SelectionModel()
    s.tap(index: 0, items: items("a"), extendingRange: false)
    s.clear()
    #expect(s.count == 0 && s.anchor == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter toggleAddsAndRemoves`
Expected: FAIL — build error "cannot find 'SelectionModel' in scope" / "cannot find 'SelectableItem' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Selection/SelectionModel.swift`:

```swift
import Foundation
import CoreGraphics

/// One selectable grid item: its id plus an optional partner that selects with
/// it atomically (a Live Photo's video half). For timeline/folder grids the
/// partner is nil; the import grid passes the Live partner.
public struct SelectableItem: Sendable, Equatable {
    public let id: String
    public let partnerID: String?
    public init(id: String, partnerID: String? = nil) {
        self.id = id; self.partnerID = partnerID
    }
}

/// UI-agnostic selection state shared by every grid (import, timeline, folder).
/// Pure value type so it can be unit-tested and held in SwiftUI `@State`.
public struct SelectionModel: Equatable, Sendable {
    public private(set) var selected: Set<String> = []
    /// Index (into the caller's ordered item list) of the last plain tap — the
    /// origin for a subsequent shift-click range.
    public var anchor: Int?
    private var dragBase: Set<String>?

    public init() {}

    public var count: Int { selected.count }
    public func contains(_ id: String) -> Bool { selected.contains(id) }

    public mutating func clear() {
        selected.removeAll(); anchor = nil; dragBase = nil
    }

    /// Flip one item (mirrors its partner).
    public mutating func toggle(_ item: SelectableItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
            if let p = item.partnerID { selected.remove(p) }
        } else {
            selected.insert(item.id)
            if let p = item.partnerID { selected.insert(p) }
        }
    }

    /// Add one item (mirrors its partner) — used for range and drag.
    public mutating func add(_ item: SelectableItem) {
        selected.insert(item.id)
        if let p = item.partnerID { selected.insert(p) }
    }

    /// Add every item (with partners). For "Select all".
    public mutating func selectAll(_ items: [SelectableItem]) {
        for it in items { add(it) }
    }

    /// Click = toggle + set anchor. Shift-click = additive range from the anchor.
    public mutating func tap(index: Int, items: [SelectableItem], extendingRange: Bool) {
        guard items.indices.contains(index) else { return }
        if extendingRange, let a = anchor, items.indices.contains(a) {
            for i in min(a, index)...max(a, index) { add(items[i]) }
            // anchor stays put across a range extension
        } else {
            toggle(items[index])
            anchor = index
        }
    }

    /// Snapshot the current selection as the base for a rubber-band drag.
    public mutating func beginDrag() { dragBase = selected; anchor = nil }

    /// Recompute selection = base ∪ (items whose frame intersects `rect`).
    public mutating func updateDrag(rect: CGRect, frames: [String: CGRect],
                                    items: [SelectableItem]) {
        var newSel = dragBase ?? selected
        for it in items where frames[it.id]?.intersects(rect) == true {
            newSel.insert(it.id)
            if let p = it.partnerID { newSel.insert(p) }
        }
        selected = newSel
    }

    public mutating func endDrag() { dragBase = nil }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SelectionModel`
Expected: PASS (all 7 `SelectionModel…`-named tests). Then `swift test` — full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Selection/SelectionModel.swift Tests/OpenPhotoCoreTests/SelectionModelTests.swift
git commit -m "$(cat <<'EOF'
feat: SelectionModel — shared, testable grid selection logic

Pure value type: toggle, shift-range, rubber-band hit-testing, and
live-pair partner expansion. Used by import/timeline/folder grids.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: ImportRegistry.deviceKeys(forHash:)

**Files:**
- Modify: `Sources/OpenPhotoCore/Import/ImportRegistry.swift`
- Test: `Tests/OpenPhotoCoreTests/ImportRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/ImportRegistryTests.swift`:

```swift
private func entryHashed(_ name: String, sourceKey: String, hash: String) -> ImportRegistry.Entry {
    ImportRegistry.Entry(sourceKey: sourceKey, name: name, size: 123,
                         takenAt: "2026-06-01T10:00:00.000Z", hash: hash,
                         importedAt: "2026-06-08T02:00:00.000Z",
                         importedTo: "rome2026/\(name)")
}

@Test func deviceKeysForHashAggregatesAcrossSourcesAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    let h = "sha256:" + String(repeating: "c", count: 64)
    try reg.append(entryHashed("IMG_1.HEIC", sourceKey: "iphone-A", hash: h))
    try reg.append(entryHashed("IMG_1.HEIC", sourceKey: "sdcard-B", hash: h))   // same bytes, 2 devices
    #expect(reg.deviceKeys(forHash: h) == ["iphone-A", "sdcard-B"])
    #expect(reg.deviceKeys(forHash: "sha256:" + String(repeating: "d", count: 64)).isEmpty)
    // Rebuilt on reload from disk.
    let reg2 = ImportRegistry(vault: vault); try reg2.load()
    #expect(reg2.deviceKeys(forHash: h) == ["iphone-A", "sdcard-B"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter deviceKeysForHashAggregatesAcrossSourcesAndPersists`
Expected: FAIL — build error "value of type 'ImportRegistry' has no member 'deviceKeys'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/OpenPhotoCore/Import/ImportRegistry.swift`, add a hash index alongside `byKey` and maintain it.

Add the property (next to `private var byKey`):

```swift
    private var byHash: [String: Set<String>] = [:]   // hash → source_keys that recorded it
```

Replace the body of `load()` so it rebuilds both indexes:

```swift
    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        byHash.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
            byHash[e.hash, default: []].insert(e.sourceKey)
        }
    }
```

In `append(_:)`, after `byKey[entry.key] = entry`, also index the hash:

```swift
        byKey[entry.key] = entry
        byHash[entry.hash, default: []].insert(entry.sourceKey)
```

Add the lookup method (after `entries(forSourceKey:)`):

```swift
    /// Device source-keys that have imported these exact bytes (any folder).
    public func deviceKeys(forHash hash: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return byHash[hash] ?? []
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter deviceKeysForHashAggregatesAcrossSourcesAndPersists`
Expected: PASS. Then `swift test` — full suite green (existing registry tests still pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Import/ImportRegistry.swift Tests/OpenPhotoCoreTests/ImportRegistryTests.swift
git commit -m "$(cat <<'EOF'
feat: ImportRegistry.deviceKeys(forHash:) — by-hash provenance index

Maintains a hash → source_keys index so we can answer "which devices is
this content known to have lived on", powering the only-copy warning.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: BackupProbe (only-copy presence)

**Files:**
- Create: `Sources/OpenPhotoCore/Presence/BackupProbe.swift`
- Test: `Tests/OpenPhotoCoreTests/BackupProbeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/BackupProbeTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func backupProbeFlagsHashesWithNoKnownDevice() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = ImportRegistry(vault: vault)
    let onPhone = "sha256:" + String(repeating: "a", count: 64)
    let macOnly = "sha256:" + String(repeating: "b", count: 64)
    try reg.append(ImportRegistry.Entry(
        sourceKey: "iphone-A", name: "IMG_1.HEIC", size: 1, takenAt: "",
        hash: onPhone, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/IMG_1.HEIC"))

    let probe = BackupProbe(registry: reg)
    #expect(probe.isOnlyOnThisMac(hash: macOnly) == true)     // never came from a device
    #expect(probe.isOnlyOnThisMac(hash: onPhone) == false)    // known on iphone-A
    #expect(probe.onlyOnThisMac(hashes: [onPhone, macOnly]) == [macOnly])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter backupProbeFlagsHashesWithNoKnownDevice`
Expected: FAIL — build error "cannot find 'BackupProbe' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Presence/BackupProbe.swift`:

```swift
import Foundation

/// Stage-A presence signal: is a given asset known to exist anywhere but this
/// Mac? Derived purely from the import registry (`imports.jsonl`). Stage C
/// replaces this with a full PresenceService (drives, sends, reconciliation).
public struct BackupProbe: Sendable {
    private let registry: ImportRegistry
    public init(registry: ImportRegistry) { self.registry = registry }

    /// Device source-keys this asset is known to have lived on.
    public func knownDeviceKeys(forHash hash: String) -> Set<String> {
        registry.deviceKeys(forHash: hash)
    }

    /// True when OpenPhoto has no record of this asset anywhere but this Mac.
    public func isOnlyOnThisMac(hash: String) -> Bool {
        knownDeviceKeys(forHash: hash).isEmpty
    }

    /// Subset of `hashes` that appear to exist only on this Mac.
    public func onlyOnThisMac(hashes: [String]) -> [String] {
        hashes.filter(isOnlyOnThisMac)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter backupProbeFlagsHashesWithNoKnownDevice`
Expected: PASS. Then `swift test` — full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Presence/BackupProbe.swift Tests/OpenPhotoCoreTests/BackupProbeTests.swift
git commit -m "$(cat <<'EOF'
feat: BackupProbe — Stage-A only-copy detection from imports.jsonl

Flags assets OpenPhoto has no record of anywhere but this Mac, so the
evict flow can warn before binning a likely-only copy.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: LibraryService.evict(_ items:) — batch evict to bin

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService.swift`
- Test: `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/LibraryServiceTests.swift` (uses the file's existing private `makeLibrary`, which creates two JPEGs):

```swift
@Test func evictBatchMovesAllToBinAndUpdatesCatalog() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let items = try lib.timelineSections().flatMap(\.items)
    #expect(items.count == 2)
    let n = try await lib.evict(items)
    #expect(n == 2)
    #expect(try lib.timelineSections().flatMap(\.items).isEmpty)
    #expect(try lib.binItems().count == 2)
}

@Test func evictSkipsMissingFilesAndCountsSuccesses() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try makeLibrary(t)
    try await lib.scanAll()
    let items = try lib.timelineSections().flatMap(\.items)
    // Remove one file out from under the catalog; evict must skip it, not throw.
    try FileManager.default.removeItem(at: lib.absoluteURL(for: items[0])!)
    let n = try await lib.evict(items)
    #expect(n == 1)                                   // the surviving file was binned
    #expect(try lib.binItems().count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter evictBatchMovesAllToBinAndUpdatesCatalog`
Expected: FAIL — build error "value of type 'LibraryService' has no member 'evict'".

- [ ] **Step 3: Write minimal implementation**

In `Sources/OpenPhotoCore/LibraryService.swift`, in the `// MARK: Delete / restore` section (after `delete(_:)`), add:

```swift
    /// Evict a selection to the bin (vault-format §8). Live pairs go atomically.
    /// Resilient: a file already gone is skipped, not fatal. One rescan + one
    /// sync-log `evict` event per vault touched. Returns the count actually binned.
    @discardableResult
    public func evict(_ items: [TimelineItem]) async throws -> Int {
        var byVault: [String: [TimelineItem]] = [:]
        for it in items { byVault[it.vaultID, default: []].append(it) }
        var evicted = 0
        for (vaultID, group) in byVault {
            guard let bin = binStores[vaultID], let v = vault(id: vaultID) else { continue }
            var n = 0
            for item in group {
                do {
                    try bin.moveToBin(relPath: item.relPath,
                                      hash: ContentHash(stringValue: item.hash), origin: .user)
                    if let pairHash = item.livePairHash,
                       let pairInstance = try catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                        try bin.moveToBin(relPath: pairInstance.relPath,
                                          hash: ContentHash(stringValue: pairHash), origin: .user)
                    }
                    n += 1
                } catch { continue }   // already gone / unreadable — skip, keep going
            }
            if n > 0 {
                appendSyncLog(vault: v, event: "evict", summary: "\(n) evicted to bin",
                              counterpartyKey: v.descriptor.vaultID)
                try await rescan(vaultID: vaultID)
            }
            evicted += n
        }
        return evicted
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "evictBatchMovesAllToBinAndUpdatesCatalog|evictSkipsMissingFilesAndCountsSuccesses"`
Expected: PASS (both). Then `swift test` — full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService.swift Tests/OpenPhotoCoreTests/LibraryServiceTests.swift
git commit -m "$(cat <<'EOF'
feat: LibraryService.evict — batch evict-to-bin for multi-select

Bins a selection (Live pairs atomic), resilient to already-missing files,
one rescan + one sync-log evict event per vault. Returns count binned.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Shared selection UI (SwiftUI)

**Files:**
- Create: `Sources/OpenPhotoApp/Selection/SelectionUI.swift`

(No unit test — `OpenPhotoApp` has no test target. Verified by `swift build` + later screen smoke tests.)

- [ ] **Step 1: Create the shared UI file**

Create `Sources/OpenPhotoApp/Selection/SelectionUI.swift`:

```swift
import SwiftUI
import OpenPhotoCore

/// Collects each cell's frame (in a named grid coordinate space) for rubber-band hit-testing.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this cell's frame in `space` for rubber-band selection.
    func cellFrame(_ id: String, in space: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: CellFramesKey.self,
                                   value: [id: geo.frame(in: .named(space))])
        })
    }

    /// Selection ring + checkbox, shown only while `show` (select mode) is true.
    @ViewBuilder
    func selectionChrome(selected: Bool, show: Bool,
                         radius: CGFloat = Theme.cellRadius) -> some View {
        if show {
            self
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Theme.accent : .black.opacity(0.45))
                        .shadow(radius: 2).padding(7)
                }
        } else {
            self
        }
    }
}

/// Rubber-band drag selection over a grid. Apply to the scrolling container; the
/// container must declare `.coordinateSpace(name: space)` and its cells must use
/// `.cellFrame(id, in: space)`. Coexists with two-finger scroll (separate input).
struct RubberBandModifier: ViewModifier {
    @Binding var selection: SelectionModel
    let items: [SelectableItem]
    let space: String
    let enabled: Bool
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragRect: CGRect?

    func body(content: Content) -> some View {
        content
            .overlay { overlayRect }
            .onPreferenceChange(CellFramesKey.self) { frames in
                Task { @MainActor in cellFrames = frames }
            }
            .simultaneousGesture(dragGesture)
    }

    @ViewBuilder private var overlayRect: some View {
        if let r = dragRect {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(space))
            .onChanged { v in
                guard enabled else { return }
                if dragRect == nil { selection.beginDrag() }
                let rect = CGRect(x: min(v.startLocation.x, v.location.x),
                                  y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x),
                                  height: abs(v.location.y - v.startLocation.y))
                dragRect = rect
                selection.updateDrag(rect: rect, frames: cellFrames, items: items)
            }
            .onEnded { _ in
                guard enabled else { return }
                selection.endDrag(); dragRect = nil
            }
    }
}

/// The toolbar shown while a grid is in select mode. (Send is added in Stage B.)
struct SelectionActionBar: View {
    let count: Int
    let onEvict: () -> Void
    let onDeselect: () -> Void
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Deselect", action: onDeselect).disabled(count == 0).controlSize(.small)
            Button(role: .destructive, action: onEvict) {
                Label("Evict…", systemImage: "trash")
            }
            .disabled(count == 0).controlSize(.small)
            Button("Done", action: onDone).controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}

/// Body text for the evict confirmation, elevated when only-copies are present.
func evictAlertMessage(total: Int, onlyCopy: Int) -> String {
    if onlyCopy > 0 {
        return "\(onlyCopy) of these appear to exist only on this Mac — OpenPhoto "
             + "has no record of them anywhere else. Everything moves to the "
             + "recoverable bin, but those aren't backed up elsewhere."
    }
    return "They'll move to the bin and can be restored anytime."
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, **zero warnings**.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Selection/SelectionUI.swift
git commit -m "$(cat <<'EOF'
feat: shared selection UI — chrome, rubber-band, action bar

Reusable SwiftUI for select mode: cell-frame publishing, selection ring +
checkbox, rubber-band drag modifier, action bar, and evict warning copy.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: AppState evict helpers

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add helpers**

In `Sources/OpenPhotoApp/AppState.swift`, add these methods inside `final class AppState` (e.g. just before `private func startWatcher`):

```swift
    /// How many of `items` appear to exist only on this Mac (no known backup).
    /// No registry yet → we can't prove a backup, so treat all as only-copies.
    func onlyCopyCount(_ items: [TimelineItem]) -> Int {
        guard let reg = importRegistry else { return items.count }
        return BackupProbe(registry: reg).onlyOnThisMac(hashes: items.map(\.hash)).count
    }

    /// Evict a selection to the bin, then refresh all queries.
    func evict(_ items: [TimelineItem]) async {
        guard let library else { return }
        do {
            _ = try await library.evict(items)
            try refreshQueries()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, zero warnings. (`BackupProbe` resolves via the existing `import OpenPhotoCore`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "$(cat <<'EOF'
feat: AppState.evict + onlyCopyCount

Centralized evict (bin + refresh) and the only-copy count used by the
evict confirmation, shared by the timeline and folder views.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Select mode in the Timeline view

**Files:**
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift` (full replacement below)

- [ ] **Step 1: Replace the file**

Replace the entire contents of `Sources/OpenPhotoApp/Timeline/TimelineView.swift` with:

```swift
import SwiftUI
import OpenPhotoCore

struct TimelineView: View {
    @Bindable var state: AppState
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false

    private var orderedSelectable: [SelectableItem] {
        state.flatItems.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        state.flatItems.filter { selection.contains($0.instanceID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            grid
        }
        .alert("Move \(selection.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let items = selectedItems
                Task {
                    await state.evict(items)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: selection.count,
                                   onlyCopy: state.onlyCopyCount(selectedItems)))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gridGap, pinnedViews: [.sectionHeaders]) {
                ForEach(state.sections, id: \.dayStartMs) { section in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                                     spacing: Theme.gridGap)],
                                  spacing: Theme.gridGap) {
                            ForEach(section.items, id: \.instanceID) { item in
                                cell(item)
                            }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
        .coordinateSpace(name: "timelinegrid")
        .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                     space: "timelinegrid", enabled: selectMode))
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { PhotoCellView(item: item, library: state.library!) }
            .clipped()
            .selectionChrome(selected: selection.contains(item.instanceID), show: selectMode)
            .cellFrame(item.instanceID, in: "timelinegrid")
            .contentShape(Rectangle())
            .onTapGesture {
                if selectMode {
                    if let idx = state.flatItems.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: state.flatItems)
                }
            }
    }

    @ViewBuilder private func sectionHeader(_ section: TimelineSection) -> some View {
        if state.grouping != .none {
            HStack {
                Text(section.title).font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(section.items.count) items")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.windowBG.opacity(0.92))
        }
    }

    private var selectionBar: some View {
        SelectionActionBar(count: selection.count,
                           onEvict: { showEvict = true },
                           onDeselect: { selection.clear() },
                           onDone: { selection.clear(); selectMode = false })
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Timeline").font(.system(size: 15, weight: .semibold))
            Text(stats).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Select") { selectMode = true }.controlSize(.small)
            Picker("Group", selection: $state.grouping) {
                Text("Day").tag(TimelineGrouping.day)
                Text("Week").tag(TimelineGrouping.week)
                Text("Month").tag(TimelineGrouping.month)
                Text("Year").tag(TimelineGrouping.year)
                Text("Continuous").tag(TimelineGrouping.none)
            }
            .pickerStyle(.menu).labelsHidden()
            .onChange(of: state.grouping) { try? state.refreshQueries() }
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 48...220).frame(width: 120)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    private var stats: String {
        let all = state.flatItems
        let v = all.filter { $0.kind == MediaKind.video.rawValue }.count
        return "\(all.count - v) photos · \(v) videos"
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, zero warnings.

- [ ] **Step 3: Smoke test**

Run: `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
Verify in the Timeline:
- Normal mode: tapping a photo still opens the viewer; the **Select** button is in the toolbar.
- Click **Select** → toolbar becomes the action bar; checkboxes/rings appear.
- Click toggles selection; **shift-click** selects a range; **click-drag** rubber-bands a region; two-finger scroll still scrolls.
- **Deselect** clears; **Done** exits select mode (tap opens viewer again).

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Timeline/TimelineView.swift
git commit -m "$(cat <<'EOF'
feat: Select mode in the Timeline (multi-select + evict)

Select button toggles checkboxes with shift-range and rubber-band drag
(shared SelectionModel/UI); action bar evicts the selection to the bin
with an only-copy warning.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Select mode in the Folder view

**Files:**
- Modify: `Sources/OpenPhotoApp/Folders/FolderGridView.swift` (full replacement below)

- [ ] **Step 1: Replace the file**

Replace the entire contents of `Sources/OpenPhotoApp/Folders/FolderGridView.swift` with:

```swift
import SwiftUI
import OpenPhotoCore

struct FolderGridView: View {
    @Bindable var state: AppState
    @State private var items: [TimelineItem] = []
    @State private var selectMode = false
    @State private var selection = SelectionModel()
    @State private var showEvict = false

    private var orderedSelectable: [SelectableItem] {
        items.map { SelectableItem(id: $0.instanceID) }
    }
    private var selectedItems: [TimelineItem] {
        items.filter { selection.contains($0.instanceID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectMode { selectionBar } else { toolbar }
            Divider().overlay(Theme.hairline)
            content
        }
        .task(id: state.selectedFolder) { reload() }
        .task(id: state.refreshToken) { reload() }      // refresh after rescans
        .alert("Move \(selection.count) to Bin?", isPresented: $showEvict) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Bin", role: .destructive) {
                let toEvict = selectedItems
                Task {
                    await state.evict(toEvict)
                    selection.clear(); selectMode = false
                }
            }
        } message: {
            Text(evictAlertMessage(total: selection.count,
                                   onlyCopy: state.onlyCopyCount(selectedItems)))
        }
    }

    @ViewBuilder private var content: some View {
        if state.selectedFolder == nil {
            ContentUnavailableView("Select a folder", systemImage: "folder")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.gridMinSize),
                                             spacing: Theme.gridGap)],
                          spacing: Theme.gridGap) {
                    ForEach(items, id: \.instanceID) { item in
                        cell(item)
                    }
                }
                .padding(12)
            }
            .coordinateSpace(name: "foldergrid")
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: "foldergrid", enabled: selectMode))
        }
    }

    @ViewBuilder private func cell(_ item: TimelineItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { PhotoCellView(item: item, library: state.library!) }
            .clipped()
            .selectionChrome(selected: selection.contains(item.instanceID), show: selectMode)
            .cellFrame(item.instanceID, in: "foldergrid")
            .contentShape(Rectangle())
            .onTapGesture {
                if selectMode {
                    if let idx = items.firstIndex(where: { $0.instanceID == item.instanceID }) {
                        selection.tap(index: idx, items: orderedSelectable,
                                      extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                } else {
                    state.openViewer(item, within: items)
                }
            }
    }

    private func reload() {
        guard let lib = state.library, let dir = state.selectedFolder else { items = []; return }
        items = (try? lib.items(inDir: dir)) ?? []
    }

    private var selectionBar: some View {
        SelectionActionBar(count: selection.count,
                           onEvict: { showEvict = true },
                           onDeselect: { selection.clear() },
                           onDone: { selection.clear(); selectMode = false })
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(state.selectedFolder?.replacingOccurrences(of: "/", with: " › ") ?? "Folders")
                .font(.system(size: 15, weight: .semibold))
            Text("\(items.count) items")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
            Spacer()
            if state.selectedFolder != nil {
                Button("Select") { selectMode = true }.controlSize(.small)
            }
            if let dir = state.selectedFolder,
               let root = state.library?.vaults.first?.rootURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [root.appendingPathComponent(dir)])
                } label: { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            Slider(value: $state.gridMinSize, in: 48...220).frame(width: 120)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, zero warnings.

- [ ] **Step 3: Smoke test**

Run: `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
Open the Folders view, pick a folder, and verify the same behaviors as Task 7 (Select, shift-range, drag, Evict with warning, Done). Confirm the **Reveal in Finder** button still works in normal mode.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "$(cat <<'EOF'
feat: Select mode in the Folder view (multi-select + evict)

Same shared select/evict UX as the timeline, scoped to the open folder.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Adopt SelectionModel in the import screen (DRY)

The import grid still carries its own bespoke selection state. Consolidate it onto the shared `SelectionModel` + shared rubber-band/cell-frame so there is one selection implementation across all three grids (the spec's "extracted from the import screen"). Behavior is unchanged.

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/ImportView.swift` (full replacement below)

- [ ] **Step 1: Replace the file**

Replace the entire contents of `Sources/OpenPhotoApp/Devices/ImportView.swift` with:

```swift
import SwiftUI
import OpenPhotoCore

struct ImportView: View {
    @Bindable var state: AppState
    let device: ConnectedDevice

    enum Phase: Equatable { case connecting, waitingForUnlock, ready, importing(done: Int, total: Int), failedToConnect(String) }
    @State private var phase: Phase = .connecting
    @State private var source: (any ImportSource)?
    @State private var items: [ImportItem] = []
    @State private var selection = SelectionModel()
    @State private var destination: String = ""
    @State private var newFolderName: String = ""
    @State private var sessionImported: [ImportEngine.ImportedItem] = []   // across batches
    @State private var sessionImportedIDs = Set<String>()
    @State private var lastResult: ImportEngine.BatchResult?
    @State private var showFreeUp = false
    @State private var stateStreamTask: Task<Void, Never>?
    @State private var importedIDCache = Set<String>()

    /// Display items (Live video halves hidden) as selectable items carrying their partner.
    private var orderedSelectable: [SelectableItem] {
        displayItems.map { SelectableItem(id: $0.id, partnerID: $0.livePartnerID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
            Divider().overlay(Theme.hairline)
            footer
        }
        .task(id: device.id) { await connect() }
        .onDisappear { stateStreamTask?.cancel() }
        .sheet(isPresented: $showFreeUp) {
            if let source, let registry = state.importRegistry,
               let lib = state.library, let vault = lib.vaults.first {
                FreeUpPhoneView(source: source, registry: registry,
                                library: lib, vault: vault,
                                deviceItems: items,
                                sessionImportedIDs: sessionImportedIDs) {
                    Task { await reloadItems() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
            Text(device.name).font(.system(size: 15, weight: .semibold))
            if case .ready = phase {
                Text("\(items.count) items · \(alreadyImportedCount) already imported")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Select all new") {
                selection.clear()
                selection.selectAll(displayItems.filter { !isImported($0) }
                    .map { SelectableItem(id: $0.id, partnerID: $0.livePartnerID) })
            }.controlSize(.small)
            Button("Deselect") { selection.clear() }.controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .connecting:
            ContentUnavailableView("Connecting…", systemImage: "cable.connector")
                .frame(maxHeight: .infinity)
        case .waitingForUnlock:
            ContentUnavailableView {
                Label("Unlock your \(device.name)", systemImage: "lock.iphone")
            } description: {
                Text("OpenPhoto is waiting — unlock the device and this screen will continue automatically.")
            }.frame(maxHeight: .infinity)
        case .failedToConnect(let why):
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
            } description: { Text(why) }.frame(maxHeight: .infinity)
        case .ready, .importing:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Theme.gridGap)],
                          spacing: Theme.gridGap) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        ImportTile(
                            item: item, source: source!,
                            alreadyImported: isImported(item),
                            importedThisSession: sessionImportedIDs.contains(item.id),
                            selected: selection.contains(item.id),
                            onToggle: {
                                selection.tap(index: index, items: orderedSelectable,
                                              extendingRange: NSEvent.modifierFlags.contains(.shift))
                            })
                            .cellFrame(item.id, in: "importgrid")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
            .coordinateSpace(name: "importgrid")
            .modifier(RubberBandModifier(selection: $selection, items: orderedSelectable,
                                         space: "importgrid", enabled: true))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch phase {
            case .importing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("Copying & verifying… \(done)/\(total) · checksum verified before any deletion")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            default:
                if let r = lastResult {
                    Label("\(r.imported.count) imported & verified" +
                          (r.skipped.isEmpty ? "" : " · \(r.skipped.count) duplicates skipped") +
                          (r.failed.isEmpty ? "" : " · \(r.failed.count) FAILED"),
                          systemImage: r.failed.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(r.failed.isEmpty ? Theme.green : Theme.amber)
                }
                Text("\(selectedDisplayCount) selected")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                Spacer()
                destinationPicker
                Button("Import \(selectedDisplayCount) items") { Task { await runBatch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDisplayCount == 0 || destination.isEmpty)
                if !sessionImported.isEmpty || hasPreviouslyImportedOnDevice {
                    Button("Free up space on \(device.name)…") { showFreeUp = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight + 8)
    }

    // MARK: Destination picker
    private var destinationPicker: some View {
        HStack(spacing: 6) {
            Picker(selection: $destination) {
                Text("Destination…").tag("")
                ForEach(allFolders, id: \.self) { f in
                    Text(f).tag(f)
                }
            } label: {
                EmptyView()
            }
            .frame(maxWidth: 200)
            TextField("New folder…", text: $newFolderName)
                .frame(width: 130)
                .onSubmit {
                    if !newFolderName.isEmpty {
                        destination = newFolderName
                        newFolderName = ""
                    }
                }
        }
    }

    // MARK: helpers

    private var displayItems: [ImportItem] {
        items.filter { !($0.kind == .video && $0.livePartnerID != nil) }
    }
    private var selectedDisplayCount: Int {
        displayItems.filter { selection.contains($0.id) }.count
    }
    private var allFolders: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { paths.append(n.path); walk(n.children) } }
        walk(state.folderTree)
        return paths.sorted()
    }
    private var alreadyImportedCount: Int { items.filter { isImported($0) }.count }
    private var hasPreviouslyImportedOnDevice: Bool {
        items.contains { isImported($0) && !sessionImportedIDs.contains($0.id) }
    }
    private func isImported(_ item: ImportItem) -> Bool {
        sessionImportedIDs.contains(item.id) || importedIDCache.contains(item.id)
    }

    private func connect() async {
        stateStreamTask?.cancel()
        stateStreamTask = nil
        phase = .connecting
        guard let src = state.deviceWatcher.source(for: device) else {
            phase = .failedToConnect("Source unavailable"); return
        }
        source = src
        if let cam = src as? CameraSource {
            stateStreamTask = Task { [weak cam] in
                guard let cam else { return }
                for await s in cam.stateStream {
                    if Task.isCancelled { break }
                    await MainActor.run { if s == .waitingForUnlock { phase = .waitingForUnlock } }
                }
            }
            do { try await cam.open() }
            catch { phase = .failedToConnect(String(describing: error)); return }
        }
        await reloadItems()
        phase = .ready
    }

    private func reloadItems() async {
        guard let source else { return }
        items = (try? await source.enumerateItems()) ?? []
        rebuildImportedCache()
    }

    private func rebuildImportedCache() {
        guard let source else { return }
        var cache = Set<String>()
        if let reg = state.importRegistry {
            for item in items {
                let taken = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
                if reg.contains(sourceKey: source.sourceKey, name: item.name,
                                size: item.byteSize, takenAt: taken) {
                    cache.insert(item.id)
                }
            }
        }
        cache.formUnion(sessionImportedIDs)
        importedIDCache = cache
    }

    private func runBatch() async {
        guard let source, let lib = state.library, let registry = state.importRegistry,
              let vault = lib.vaults.first else { return }
        let batchItems = items.filter { selection.contains($0.id) }
        phase = .importing(done: 0, total: batchItems.count)
        let engine = ImportEngine(library: lib, registry: registry)
        let result = await engine.run(source: source, items: batchItems,
                                      vault: vault, dirPath: destination) { p in
            Task { @MainActor in phase = .importing(done: p.done, total: p.total) }
        }
        lastResult = result
        sessionImported.append(contentsOf: result.imported)
        sessionImportedIDs.formUnion(result.imported.map(\.item.id))
        rebuildImportedCache()
        selection.clear()
        try? state.refreshQueries()
        phase = .ready
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete, zero warnings. (`CellFramesKey` now lives only in `SelectionUI.swift`; this file no longer declares it.)

- [ ] **Step 3: Smoke test (import must be unchanged)**

Run: `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
With the fixture SD card (or iPhone): open the import grid and verify unchanged behavior — click toggles, **shift-click** range, **click-drag** rubber-band, **Select all new**, **Deselect**, a Live-pair tile still selects/imports both halves, and a batch import still works end-to-end.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Devices/ImportView.swift
git commit -m "$(cat <<'EOF'
refactor: import grid uses the shared SelectionModel + selection UI

Removes ImportView's bespoke selection/anchor/drag state in favor of the
shared SelectionModel, CellFramesKey, and RubberBandModifier — one
selection implementation across import, timeline, and folder grids.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `swift build` — zero warnings.
- [ ] `swift test` — full suite green (was 71; now +~11 new tests).
- [ ] App smoke: Select → multi-select (click / shift / drag) → Evict → only-copy warning → confirm → photos leave the grid and appear in the **Bin** view → restore one from the Bin → it returns. Works in both Timeline and Folders. Import grid unchanged.

## Self-review (completed while writing)

- **Spec coverage (Stage A):** shared SelectionController → Task 1 (`SelectionModel`) + Task 5 (shared UI) + adoption in Tasks 7–9; Select in timeline+folder → Tasks 7–8; evict-to-bin via BinStore → Task 4; only-copy warning from catalog + imports.jsonl → Tasks 2, 3, 6, and the alert in Tasks 7–8. Safety: eviction is the §8 recoverable bin (spec §5 "bin makes eviction recoverable").
- **Type consistency:** `SelectableItem(id:partnerID:)`, `SelectionModel.tap(index:items:extendingRange:)` / `.toggle` / `.selectAll` / `.beginDrag`/`.updateDrag`/`.endDrag` / `.clear` / `.contains` / `.count`; `ImportRegistry.deviceKeys(forHash:)`; `BackupProbe(registry:)` `.onlyOnThisMac(hashes:)` `.isOnlyOnThisMac(hash:)`; `LibraryService.evict(_:) -> Int`; `AppState.onlyCopyCount(_:)` / `evict(_:)`; SwiftUI helpers `cellFrame(_:in:)`, `selectionChrome(selected:show:)`, `RubberBandModifier(selection:items:space:enabled:)`, `SelectionActionBar(count:onEvict:onDeselect:onDone:)`, `evictAlertMessage(total:onlyCopy:)` — all used consistently across tasks.
- **No placeholders:** every code step is complete; the three modified views are shown in full.
