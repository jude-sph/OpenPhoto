# Background Sync — live progress, minimize, cancel, failure report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a sync to the canonical drive a first-class background job: byte-accurate progress with speed + ETA, minimize-to-background with a sidebar chip, a ~1s graceful Cancel, and an actionable failure report with retry — without regressing the atomic/hash-verified/idempotent-resume guarantees.

**Architecture:** Core gets a streaming `VerifiedCopy` (chunked, per-byte progress, cancellable, single-pass SHA-256), a richer progress/result/failure model, an engine that reports bytes + honors cancel + classifies failures, and a pure `SyncRateMeter`. The App lifts the sync out of the sheet into `AppState` (stored cancellable Task + `syncActivity`), presents the sheet at the app root so it's reopenable from anywhere, and adds a sidebar chip.

**Tech Stack:** Swift, SwiftUI, CryptoKit (SHA-256), swift-testing (`@Test`). SwiftPM: `swift test`, `swift build`, `scripts/make-app.sh`.

**Spec:** `docs/superpowers/specs/2026-06-24-sync-background-progress-design.md`

---

## Notes for the implementer

- **SwiftPM package** (no Xcode project). `swift test` runs Core tests; `swift build` builds the app; `scripts/make-app.sh` packages the universal `.app`. Tests use **swift-testing** (`import Testing`, `@Test`), temp dirs via the existing `TestDirs` helper.
- **Never touch real user data.** Tests use temp files only.
- **The streamed SHA-256 must equal `ContentHash.ofFile`** (same algorithm: SHA-256 over the whole byte stream, `"sha256:" + hex`). Chunk size doesn't change the digest. Task 1 has a parity test.
- **`@Observable` constraint:** the `@Observable` macro only tracks stored properties declared in `AppState`'s primary body. So the sync **stored properties go in `AppState.swift`** (internal access, NOT `private`, so the extension file can use them); the **methods go in `AppState+Sync.swift`**.
- The app (`OpenPhotoApp`) has **no unit-test target** — UI tasks are build-verified + manually smoke-tested. All *logic* (copy, classification, rate meter) lives in tested Core.
- Branch `feature/sync-background-progress` already exists and is checked out. Commit after each task.

## File structure

**Create (Core):** `Sources/OpenPhotoCore/Sync/SyncFailure.swift` (reasons + FailedItem), `Sources/OpenPhotoCore/Sync/SyncRateMeter.swift`.
**Modify (Core):** `VerifiedCopy.swift` (streaming), `SyncPlan.swift` (progress+bytes, result model), `SyncEngine.swift` (apply).
**Create (App):** `Sources/OpenPhotoApp/AppState+Sync.swift` (sync methods).
**Modify (App):** `AppState.swift` (sync stored props), `OpenPhotoApp.swift` (root sheet), `Drives/DrivesView.swift` (Sync buttons → state), `Drives/SyncPlanSheet.swift` (phases + failure report), `Sidebar/SidebarView.swift` (chip).
**Create (Tests):** `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`, `Tests/OpenPhotoCoreTests/SyncRateMeterTests.swift`. **Modify:** `Tests/OpenPhotoCoreTests/SyncApplyTests.swift`.

---

## Task 1: Streaming `VerifiedCopy` + failure model (Core, TDD)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/SyncFailure.swift`
- Modify: `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift` (full rewrite)
- Test: `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`:
```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func tmpDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("vc-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
private func writeFile(_ url: URL, bytes: Int) throws -> String {
    var d = Data(count: 0); d.reserveCapacity(bytes)
    var x: UInt8 = 7
    for _ in 0..<bytes { x = x &* 31 &+ 11; d.append(x) }
    try d.write(to: url)
    return try ContentHash.ofFile(at: url).stringValue
}

@Test func streamingCopySucceedsAndVerifies() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("out/dst.bin")
    let hash = try writeFile(src, bytes: 9 << 20)            // 9 MB → multiple 4MB chunks
    var bytesSeen: [Int64] = []
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: hash,
                                    onBytes: { bytesSeen.append($0) }, shouldCancel: { false })
    #expect(outcome == .copied)
    #expect(FileManager.default.fileExists(atPath: dst.path))
    #expect(try ContentHash.ofFile(at: dst).stringValue == hash)          // bytes identical
    #expect(bytesSeen.last == Int64(9 << 20))                              // ends at file size
    #expect(bytesSeen == bytesSeen.sorted())                              // monotonic
    // no temp left behind
    #expect(try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
              .filter { $0.hasPrefix(".tmp-") }.isEmpty)
}

@Test func streamedHashEqualsContentHash() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("a.bin"); let dst = dir.appendingPathComponent("b.bin")
    let hash = try writeFile(src, bytes: (4 << 20) + 123)   // not a chunk multiple
    #expect(VerifiedCopy.copy(from: src, to: dst, expectedHash: hash) == .copied)
}

@Test func cancelMidStreamLeavesNoTemp() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    let hash = try writeFile(src, bytes: 20 << 20)
    var calls = 0
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: hash,
                                    onBytes: { _ in }, shouldCancel: { calls += 1; return calls > 1 })
    #expect(outcome == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: dst.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
              .filter { $0.hasPrefix(".tmp-") }.isEmpty)
}

@Test func hashMismatchIsFailureNoDest() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    _ = try writeFile(src, bytes: 1 << 20)
    let outcome = VerifiedCopy.copy(from: src, to: dst, expectedHash: "sha256:deadbeef")
    #expect(outcome == .failed(.hashMismatch))
    #expect(!FileManager.default.fileExists(atPath: dst.path))
}

@Test func neverOverwritesExistingDest() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.bin"); let dst = dir.appendingPathComponent("dst.bin")
    let hash = try writeFile(src, bytes: 1024)
    try "occupied".data(using: .utf8)!.write(to: dst)
    #expect(VerifiedCopy.copy(from: src, to: dst, expectedHash: hash) == .failed(.conflict))
    #expect(try Data(contentsOf: dst) == "occupied".data(using: .utf8)!)
}

@Test func missingSourceIsFailure() throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = VerifiedCopy.copy(from: dir.appendingPathComponent("nope.bin"),
                                    to: dir.appendingPathComponent("dst.bin"), expectedHash: "sha256:x")
    #expect(outcome == .failed(.sourceMissing))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VerifiedCopyTests`
Expected: FAIL — `SyncFailureReason`/`CopyOutcome` undefined / signature mismatch.

- [ ] **Step 3: Create the failure model**

`Sources/OpenPhotoCore/Sync/SyncFailure.swift`:
```swift
import Foundation

/// Why a single file didn't sync. Drives the user-facing failure report + retry.
public enum SyncFailureReason: String, Sendable, Equatable {
    case sourceMissing   // source file gone / unreadable
    case copyFailed      // I/O writing to the drive (disk full, permissions, drive disconnected)
    case hashMismatch    // copied bytes didn't verify — temp discarded
    case conflict        // a DIFFERENT file already occupies that path (never overwritten)

    public var userText: String {
        switch self {
        case .sourceMissing: return "source file missing"
        case .copyFailed:    return "copy failed (drive full or disconnected)"
        case .hashMismatch:  return "checksum mismatch"
        case .conflict:      return "a different file is already there"
        }
    }
    /// Conflicts need a real decision; everything else is worth retrying.
    public var isRetryable: Bool { self != .conflict }
}

public struct FailedItem: Sendable, Equatable {
    public let item: PlanItem
    public let reason: SyncFailureReason
    public init(item: PlanItem, reason: SyncFailureReason) { self.item = item; self.reason = reason }
}
```

- [ ] **Step 4: Rewrite `VerifiedCopy` as a streaming copy**

Replace the entire body of `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift`:
```swift
import Foundation
import CryptoKit

public enum CopyOutcome: Sendable, Equatable { case copied, cancelled, failed(SyncFailureReason) }

public enum VerifiedCopy {
    /// Stream-copy `source` → `dest`: chunk read → temp write → incremental SHA-256, with per-byte
    /// progress and ~chunk-granular cancellation. Atomic (temp → fsync → rename); the destination is
    /// never left partial; an existing dest is never overwritten. The streamed digest is identical to
    /// `ContentHash.ofFile` (SHA-256 over the whole byte stream).
    @discardableResult
    public static func copy(from source: URL, to dest: URL, expectedHash: String,
                            chunkBytes: Int = 4 << 20,
                            onBytes: (@Sendable (Int64) -> Void)? = nil,
                            shouldCancel: (@Sendable () -> Bool)? = nil) -> CopyOutcome {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return .failed(.conflict) }  // caller pre-checks; defensive
        do { try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return .failed(.copyFailed) }
        guard let inFH = try? FileHandle(forReadingFrom: source) else { return .failed(.sourceMissing) }
        defer { try? inFH.close() }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        guard fm.createFile(atPath: tmp.path, contents: nil),
              let outFH = try? FileHandle(forWritingTo: tmp) else { return .failed(.copyFailed) }
        var keepTemp = false
        defer { try? outFH.close(); if !keepTemp { try? fm.removeItem(at: tmp) } }

        var hasher = SHA256()
        var written: Int64 = 0
        while true {
            if shouldCancel?() == true { return .cancelled }
            let chunk: Data
            do { chunk = try autoreleasepool { try inFH.read(upToCount: chunkBytes) } ?? Data() }
            catch { return .failed(.sourceMissing) }
            if chunk.isEmpty { break }
            do { try outFH.write(contentsOf: chunk) } catch { return .failed(.copyFailed) }
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            onBytes?(written)
        }
        do { try outFH.synchronize() } catch { return .failed(.copyFailed) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + hex == expectedHash else { return .failed(.hashMismatch) }
        do { try fm.moveItem(at: tmp, to: dest) } catch { return .failed(.copyFailed) }
        keepTemp = true
        return .copied
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter VerifiedCopyTests`
Expected: PASS (all 6).

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncFailure.swift Sources/OpenPhotoCore/Sync/VerifiedCopy.swift Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift
git commit -m "feat(core): streaming VerifiedCopy with per-byte progress + cancel + failure reasons"
```

---

## Task 2: Progress/result model + `SyncEngine.apply` (Core, TDD)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/SyncPlan.swift` (SyncProgress + SyncResult)
- Modify: `Sources/OpenPhotoCore/Sync/SyncEngine.swift` (apply)
- Test: `Tests/OpenPhotoCoreTests/SyncApplyTests.swift` (update existing + add new)

- [ ] **Step 1: Update the model in `SyncPlan.swift`**

In `Sources/OpenPhotoCore/Sync/SyncPlan.swift`, change `SyncProgress` and `SyncResult`:
```swift
public struct SyncProgress: Sendable {
    public enum Stage: String, Sendable { case copying, verifying, finishing }
    public let stage: Stage
    public let done: Int
    public let total: Int
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentName: String
    public init(stage: Stage, done: Int, total: Int, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
                currentName: String) {
        self.stage = stage; self.done = done; self.total = total
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.currentName = currentName
    }
}

public struct SyncResult: Sendable, Equatable {
    public var copied = 0
    public var sidecarsWritten = 0
    public var skipped = 0
    public var failed: [FailedItem] = []
    public var cancelled = false
    public init() {}
    /// Files skipped because a DIFFERENT file already occupies the path.
    public var conflicts: Int { failed.filter { $0.reason == .conflict }.count }
    /// Genuine transient failures (everything retryable).
    public var retryableFailures: [FailedItem] { failed.filter { $0.reason.isRetryable } }
}
```

- [ ] **Step 2: Update the failing tests in `SyncApplyTests.swift`**

Open `Tests/OpenPhotoCoreTests/SyncApplyTests.swift`. The existing tests reference `result.failed` (as `[PlanItem]`) and `result.conflicts` (as a stored count). Update assertions to the new model: `result.failed` is `[FailedItem]`, `result.conflicts` is computed. For the existing `applyResumesWithMatchingPartialAndNeverOverwritesDifferent` test, change any `result.failed.contains(item)` to `result.failed.contains { $0.item == item }` and any conflict assertion to `#expect(result.conflicts == 1)`. Then ADD these new tests at the end of the file (use the file's existing helpers for building a plan/drive — mirror the existing setup):

```swift
@Test func applyReportsByteProgressToTotal() async throws {
    // Build a plan with 2 small files (reuse this file's existing plan/drive setup helpers).
    // Assert: the last copying SyncProgress has bytesDone == bytesTotal == plan.totalCopyBytes,
    //         and bytesDone is non-decreasing across callbacks.
    // (Implement using the same harness as applyResumes…; collect progress into an array.)
}

@Test func applyCancelStopsAndStillWritesManifest() async throws {
    // Build a plan with >=2 copies. Pass shouldCancel returning true after the first file is counted.
    // Assert: result.cancelled == true; result.copied < plan.copies.count; and re-reading the drive
    //         manifest shows the file(s) copied before cancel (resume works).
}

@Test func applyClassifiesConflictNotRetryable() async throws {
    // Place a DIFFERENT file at a dest path (wrong hash). Assert the item lands in result.failed with
    // reason == .conflict, result.conflicts == 1, and result.retryableFailures is empty.
}
```
(When implementing these, follow the exact harness already in `SyncApplyTests.swift` — same `Catalog`/`Vault`/`DriveVolume`/`SyncEngine` construction. Collect progress callbacks into a local `var progresses: [SyncProgress] = []` captured in the closure.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SyncApply`
Expected: FAIL — `apply` doesn't take `shouldCancel`, doesn't report bytes, `result.failed` type mismatch.

- [ ] **Step 4: Rewrite `apply` in `SyncEngine.swift`**

Replace the `apply(...)` method (lines ~120–207) signature + body. Key changes vs current:
- Signature gains `shouldCancel: (@Sendable () -> Bool)? = nil` before `progress:`.
- Remove `result.conflicts = plan.conflicts.count` (conflicts now live in `failed`). Seed conflicts: `for item in plan.conflicts { result.failed.append(FailedItem(item: item, reason: .conflict)) }`.
- Free-space guard: `result.failed = plan.copies.map { FailedItem(item: $0, reason: .copyFailed) }; return result`.
- Track bytes; per-file: cancel check → break; use streaming `VerifiedCopy` with `onBytes`/`shouldCancel`; classify outcome.
- Skip sidecars when cancelled; ALWAYS write the manifest.

```swift
public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                  event: String = "sync", counterpartyVaultID: String? = nil,
                  shouldCancel: (@Sendable () -> Bool)? = nil,
                  progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
    let fm = FileManager.default
    var result = SyncResult()
    for item in plan.conflicts { result.failed.append(FailedItem(item: item, reason: .conflict)) }

    if let free = try? volume.freeSpaceBytes(), free < plan.totalCopyBytes {
        result.failed.append(contentsOf: plan.copies.map { FailedItem(item: $0, reason: .copyFailed) })
        return result
    }

    var verified: [String: ManifestEntry] = [:]
    if let prior = try? Manifest.read(from: drive.manifestURL) {
        for e in prior where fm.fileExists(atPath: drive.rootURL.appendingPathComponent(e.path).path) {
            verified[e.path] = e
        }
    }

    let total = plan.copies.count
    let bytesTotal = plan.totalCopyBytes
    var bytesDone: Int64 = 0
    for (i, item) in plan.copies.enumerated() {
        if shouldCancel?() == true { result.cancelled = true; break }
        let name = (item.destRelPath as NSString).lastPathComponent
        let base = bytesDone
        progress?(SyncProgress(stage: .copying, done: i, total: total,
                               bytesDone: base, bytesTotal: bytesTotal, currentName: name))
        let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
        do {
            if fm.fileExists(atPath: destURL.path) {
                let onDisk = try ContentHash.ofFile(at: destURL).stringValue
                if onDisk == item.hash {
                    verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                    result.skipped += 1; bytesDone += item.size; continue
                } else {
                    result.failed.append(FailedItem(item: item, reason: .conflict)); continue
                }
            }
            let outcome = VerifiedCopy.copy(
                from: item.sourceURL, to: destURL, expectedHash: item.hash,
                onBytes: { fileBytes in
                    progress?(SyncProgress(stage: .copying, done: i, total: total,
                                           bytesDone: base + fileBytes, bytesTotal: bytesTotal,
                                           currentName: name))
                },
                shouldCancel: { shouldCancel?() == true })
            switch outcome {
            case .copied:
                verified[item.destRelPath] = try Self.manifestEntry(for: item, at: destURL)
                result.copied += 1; bytesDone += item.size
            case .cancelled:
                result.cancelled = true
            case .failed(let reason):
                result.failed.append(FailedItem(item: item, reason: reason))
            }
            if result.cancelled { break }
        } catch {
            result.failed.append(FailedItem(item: item, reason: .copyFailed))
        }
    }

    if !result.cancelled {
        for item in plan.sidecarUpdates {
            let destURL = drive.rootURL.appendingPathComponent(item.destRelPath)
            do {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicFile.write(try Data(contentsOf: item.sourceURL), to: destURL)
                result.sidecarsWritten += 1
            } catch { result.failed.append(FailedItem(item: item, reason: .copyFailed)) }
        }
    }

    progress?(SyncProgress(stage: .finishing, done: total, total: total,
                           bytesDone: bytesDone, bytesTotal: bytesTotal, currentName: ""))
    try? Manifest.write(verified.values.sorted { $0.path < $1.path }, to: drive.manifestURL)

    let summary = "\(result.copied) copied, \(result.skipped) skipped, " +
                  "\(result.sidecarsWritten) sidecars, \(result.conflicts) conflicts, " +
                  "\(result.retryableFailures.count) failed" + (result.cancelled ? ", cancelled" : "")
    if event == "sync" {
        library.appendSyncLog(vault: drive, event: "sync", summary: summary,
                              counterpartyKey: library.vaults.first?.descriptor.vaultID ?? "")
        if let mac = library.vaults.first {
            library.appendSyncLog(vault: mac, event: "sync", summary: summary,
                                  counterpartyKey: drive.descriptor.vaultID)
        }
    } else {
        library.appendSyncLog(vault: drive, event: event, summary: summary,
                              counterpartyKey: counterpartyVaultID ?? "")
    }
    return result
}
```

- [ ] **Step 5: Find + fix any other `SyncResult` consumers**

Run: `grep -rn "\.failed\b\|result.conflicts\|SyncResult" Sources --include=*.swift | grep -iv test`
Update any consumer that treated `failed` as `[PlanItem]` or `conflicts` as a stored var (notably `SyncPlanSheet.resultView` is handled in Task 6; the `DriftReconciler`/clone callers, if any, only read counts — adjust to the computed `conflicts`). Make the whole package compile: `swift build 2>&1 | grep -E "error:|Build complete"`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SyncApply`
Expected: PASS (existing resume test + 3 new). Implement the 3 new test bodies fully against the file's harness before this passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncPlan.swift Sources/OpenPhotoCore/Sync/SyncEngine.swift Tests/OpenPhotoCoreTests/SyncApplyTests.swift
git commit -m "feat(core): SyncEngine byte progress + graceful cancel + classified failures"
```

---

## Task 3: `SyncRateMeter` (Core, TDD)

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/SyncRateMeter.swift`
- Test: `Tests/OpenPhotoCoreTests/SyncRateMeterTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/OpenPhotoCoreTests/SyncRateMeterTests.swift`:
```swift
import Testing
@testable import OpenPhotoCore

@Test func rateMeterSteadySpeedAndEta() {
    var m = SyncRateMeter(alpha: 0.5)
    let total: Int64 = 1000
    var out = m.update(bytesDone: 0, bytesTotal: total, now: 0)     // first sample: warm-up
    #expect(out.eta == nil)
    out = m.update(bytesDone: 100, bytesTotal: total, now: 1)       // 100 B/s
    out = m.update(bytesDone: 200, bytesTotal: total, now: 2)       // steady 100 B/s
    #expect(abs(out.speed - 100) < 1)
    #expect(out.eta != nil)
    #expect(abs(out.eta! - 8) < 0.5)                                // (1000-200)/100 = 8s
}

@Test func rateMeterNoEtaUntilWarm() {
    var m = SyncRateMeter()
    #expect(m.update(bytesDone: 0, bytesTotal: 100, now: 0).eta == nil)
    #expect(m.update(bytesDone: 10, bytesTotal: 100, now: 1).eta == nil)  // only 1 interval
}
```

- [ ] **Step 2: Run to verify failure** — Run: `swift test --filter SyncRateMeter` → FAIL (undefined).

- [ ] **Step 3: Implement**

`Sources/OpenPhotoCore/Sync/SyncRateMeter.swift`:
```swift
import Foundation

/// Pure smoothed-throughput + ETA estimator. Feed cumulative (bytesDone, monotonic time); get a
/// stable EMA speed and an ETA (nil until warmed up). No Date/clock inside — caller passes `now`.
public struct SyncRateMeter {
    private var ema = 0.0
    private var lastBytes: Int64 = 0
    private var lastTime = 0.0
    private var samples = 0
    private let alpha: Double
    public init(alpha: Double = 0.2) { self.alpha = alpha }

    public mutating func update(bytesDone: Int64, bytesTotal: Int64, now: Double)
        -> (speed: Double, eta: Double?) {
        defer { lastBytes = bytesDone; lastTime = now; samples += 1 }
        guard samples >= 1 else { return (0, nil) }                 // first call = warm-up
        let dt = now - lastTime
        if dt > 0 {
            let inst = Double(max(0, bytesDone - lastBytes)) / dt
            ema = samples == 1 ? inst : alpha * inst + (1 - alpha) * ema
        }
        let eta: Double? = (samples >= 2 && ema > 1) ? Double(max(0, bytesTotal - bytesDone)) / ema : nil
        return (ema, eta)
    }
}
```

- [ ] **Step 4: Run** — `swift test --filter SyncRateMeter` → PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/OpenPhotoCore/Sync/SyncRateMeter.swift Tests/OpenPhotoCoreTests/SyncRateMeterTests.swift
git commit -m "feat(core): SyncRateMeter (smoothed speed + ETA)"
```

---

## Task 4: AppState sync activity (App, build-verify)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (stored props only)
- Create: `Sources/OpenPhotoApp/AppState+Sync.swift` (methods)

- [ ] **Step 1: Add the observable model + stored props to `AppState.swift`**

Near the People/derivation state (~line 85), add (INTERNAL access so the extension can use them):
```swift
    // MARK: — Sync activity (one active sync at a time; survives the sheet closing)
    var syncActivity: SyncActivity?            // observable snapshot the UI reads
    var syncSheetDrive: Vault?                 // non-nil → present the sync sheet (root-level)
    var syncTask: Task<Void, Never>?
    var syncCancelRequested = false
    var syncDrive: Vault?                      // the drive being synced (for chip → reopen)
```
And add the model type (top-level, in `AppState.swift` or a small file — put it in `AppState+Sync.swift` Step 2):

- [ ] **Step 2: Create `AppState+Sync.swift`**

```swift
import SwiftUI
import OpenPhotoCore

struct SyncActivity: Sendable {
    enum Phase: Sendable, Equatable { case running, finished, cancelled }
    var driveName: String
    var stage: SyncProgress.Stage
    var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    var filesDone = 0, filesTotal = 0
    var currentName = ""
    var speedBytesPerSec = 0.0
    var etaSeconds: Double?
    var phase: Phase = .running
    var result: SyncResult?                    // set when phase != .running
}

extension AppState {
    /// Start a background sync to `drive`. Stores a cancellable Task; streams progress into
    /// `syncActivity` (speed/ETA via SyncRateMeter). Post-sync bookkeeping (presence, deletions,
    /// snapshot, albums) runs here so it survives the sheet being minimized.
    func startSync(plan: SyncPlan, drive: Vault, chosenDeletions: [PendingDeletion] = []) {
        guard syncTask == nil, let lib = library else { return }
        let volume = FileSystemVolume(rootURL: drive.rootURL)
        syncCancelRequested = false
        syncDrive = drive
        syncActivity = SyncActivity(driveName: drive.rootURL.lastPathComponent, stage: .copying,
                                    bytesTotal: plan.totalCopyBytes, filesTotal: plan.copies.count)
        let engine = SyncEngine(library: lib)
        let start = Date()
        syncTask = Task { [weak self] in
            var meter = SyncRateMeter()
            let r = await engine.apply(plan, destinationVault: drive, volume: volume,
                shouldCancel: { [weak self] in self?.syncCancelRequested ?? true },
                progress: { p in
                    Task { @MainActor [weak self] in
                        guard let self, var a = self.syncActivity else { return }
                        let (speed, eta) = meter.update(bytesDone: p.bytesDone, bytesTotal: p.bytesTotal,
                                                        now: Date().timeIntervalSince(start))
                        a.stage = p.stage; a.bytesDone = p.bytesDone; a.bytesTotal = p.bytesTotal
                        a.filesDone = p.done; a.currentName = p.currentName
                        a.speedBytesPerSec = speed; a.etaSeconds = eta
                        self.syncActivity = a
                    }
                })
            await self?.finishSync(result: r, drive: drive, chosenDeletions: chosenDeletions)
        }
    }

    @MainActor private func finishSync(result r: SyncResult, drive: Vault,
                                       chosenDeletions: [PendingDeletion]) async {
        // (Moved verbatim from the old SyncPlanSheet.runApply post-apply block.)
        try? refreshCanonicalPresence(driveVault: drive)
        refreshPendingDeletions()
        let pending = drivePendingDeletions[drive.descriptor.vaultID] ?? []
        let chosen = pending.filter { p in chosenDeletions.contains { $0.hash == p.hash } }
        if !chosen.isEmpty { _ = await propagateDeletions(drive: drive, selected: chosen) }
        if let lib = library {
            let cat = lib.catalog, thumbs = lib.thumbnails, syncedDrive = drive
            let macRoot = lib.vaults.first?.rootURL
            await Task.detached(priority: .utility) {
                try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: syncedDrive)
                if let macRoot { try? AlbumStore.syncToDrive(libraryRoot: macRoot, driveStateDir: syncedDrive.stateDirURL) }
            }.value
        }
        var a = syncActivity ?? SyncActivity(driveName: drive.rootURL.lastPathComponent, stage: .finishing)
        a.phase = r.cancelled ? .cancelled : .finished
        a.result = r
        syncActivity = a
        syncTask = nil
    }

    func cancelSync() { syncCancelRequested = true }

    /// Re-run a sync for just the selected previously-failed items.
    func retrySyncFailures(_ items: [PlanItem], drive: Vault) {
        guard syncTask == nil else { return }
        var plan = SyncPlan()
        plan.copies = items
        plan.totalCopyBytes = items.reduce(0) { $0 + $1.size }
        startSync(plan: plan, drive: drive)
    }

    func dismissSyncResult() {
        guard syncTask == nil else { return }   // don't clear a running sync
        syncActivity = nil; syncDrive = nil; syncSheetDrive = nil
    }
}
```
(If `refreshCanonicalPresence`/`refreshPendingDeletions`/`propagateDeletions`/`drivePendingDeletions`/`FileSystemVolume`/`CatalogSnapshot`/`AlbumStore` symbols are declared `private` in AppState, relax to internal so the extension can call them — they're the same ones the old `runApply` used.)

- [ ] **Step 3: Add the teardown cancel**

Find where `derivationTask?.cancel()` is called on library close (AppState.swift ~line 1850) and add next to it: `syncTask?.cancel(); syncTask = nil; syncActivity = nil`.

- [ ] **Step 4: Build-verify**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: errors only from `SyncPlanSheet` still calling the old `apply` (fixed in Task 6) — comment out the body of `SyncPlanSheet.runApply` temporarily if needed to get a clean Core+AppState compile, OR proceed to Task 5/6 which fix it. (If you keep it compiling, leave `runApply` intact until Task 6.)

- [ ] **Step 5: Commit**
```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/AppState+Sync.swift
git commit -m "feat(app): background sync activity in AppState (start/cancel/retry/dismiss + speed/ETA)"
```

---

## Task 5: Root-level sync sheet + DrivesView wiring (App, build-verify)

**Files:**
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift` (present the sync sheet at the root)
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift` (Sync buttons set `state.syncSheetDrive`)

- [ ] **Step 1: Present the sheet at the root** so it's reopenable from anywhere (the sidebar chip lives outside DrivesView). In `OpenPhotoApp.swift`'s `RootView` (the `detail`/root container, ~line 119), add to the root view:
```swift
.sheet(item: $state.syncSheetDrive) { drive in SyncPlanSheet(state: state, drive: drive) }
```
(`Vault` must be `Identifiable` for `.sheet(item:)`. It already is where `DrivesView` uses `.sheet(item: $syncDrive)`. Use the same conformance.)

- [ ] **Step 2: Route DrivesView's Sync buttons through AppState.** In `Drives/DrivesView.swift`, replace the local `@State private var syncDrive: Vault?` usage for SYNC with `state.syncSheetDrive`:
  - Remove `.sheet(item: $syncDrive) { drive in SyncPlanSheet(...) }` (line 34) — it's now at the root.
  - Change the two `syncDrive = state.openVault(for: vr)` (lines 163, 228) to `state.syncSheetDrive = state.openVault(for: vr)`.
  - Keep the other sheets (`drift`, `deletionDrive`, `consensusRepair`) as-is.

- [ ] **Step 3: Build-verify** — Run: `swift build 2>&1 | grep -E "error:|Build complete"`. (SyncPlanSheet still uses old apply — Task 6.)

- [ ] **Step 4: Commit**
```bash
git add Sources/OpenPhotoApp/OpenPhotoApp.swift Sources/OpenPhotoApp/Drives/DrivesView.swift
git commit -m "feat(app): present sync sheet at root, route Sync through AppState.syncSheetDrive"
```

---

## Task 6: SyncPlanSheet — phases + cancel/minimize + failure report (App, build-verify)

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`

- [ ] **Step 1: Drive the sheet off `state.syncActivity`.** Rewrite the sheet so:
  - **Confirm phase** (`state.syncActivity == nil`): keep the existing plan preview + deletions list. The **Sync** button calls `state.startSync(plan: plan, drive: drive, chosenDeletions: chosenDeletions)` then `dismiss()` is NOT called (the sheet flips to running). Remove the local `runApply` (its post-apply work moved to `AppState.finishSync`).
  - **Running phase** (`activity.phase == .running`): byte progress + speed + ETA + Cancel + Minimize:
```swift
@ViewBuilder private func runningView(_ a: SyncActivity) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        ProgressView(value: Double(a.bytesDone), total: Double(max(a.bytesTotal, 1))).tint(Theme.accent)
        Text("\(byteString(a.bytesDone)) / \(byteString(a.bytesTotal)) · \(speedString(a.speedBytesPerSec))"
             + (a.etaSeconds.map { " · ~\(etaString($0)) left" } ?? ""))
            .font(.system(size: 13).monospacedDigit())
        Text("\(a.stage.rawValue.capitalized) \(a.currentName) · \(a.filesDone)/\(a.filesTotal) files")
            .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
        Spacer()
        HStack {
            Button("Cancel", role: .destructive) { state.cancelSync() }
            Spacer()
            Button("Minimize") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }.padding(24)
}
```
  - **Finished/cancelled phase**: if `a.result?.failed.isEmpty != false` (no failures) → success summary + Done (`state.dismissSyncResult(); dismiss()`). Else → the failure report.

  Helpers: `speedString` (`ByteCountFormatter` + "/s"), `etaString` (`DateComponentsFormatter`, .abbreviated, e.g. "14 min").

- [ ] **Step 2: Failure report** (finished phase, when `!result.failed.isEmpty`):
```swift
@State private var showThumbs = false
@State private var retrySelection: Set<String> = []   // by item.destRelPath

@ViewBuilder private func failureView(_ r: SyncResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Label("\(r.failed.count) of \(r.copied + r.failed.count) files didn’t sync",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Spacer()
            Toggle("Thumbnails", isOn: $showThumbs).toggleStyle(.switch).controlSize(.mini)
        }
        List(r.failed, id: \.item.destRelPath) { f in
            HStack(spacing: 8) {
                if f.reason.isRetryable {
                    Toggle("", isOn: Binding(
                        get: { retrySelection.contains(f.item.destRelPath) },
                        set: { on in if on { retrySelection.insert(f.item.destRelPath) }
                                     else { retrySelection.remove(f.item.destRelPath) } }))
                        .labelsHidden()
                } else { Image(systemName: "slash.circle").foregroundStyle(Theme.textFaint) }
                if showThumbs {
                    FaceLikeThumb(state: state, hash: f.item.hash)   // small crop via thumbnail cache
                        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text((f.item.destRelPath as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(f.reason.userText).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
        }.frame(maxHeight: .infinity)
        HStack {
            Button("Retry \(retrySelection.count) selected") {
                let items = r.failed.filter { retrySelection.contains($0.item.destRelPath) }.map(\.item)
                state.retrySyncFailures(items, drive: drive)
            }.disabled(retrySelection.isEmpty)
            Spacer()
            Button("Done") { state.dismissSyncResult(); dismiss() }.keyboardShortcut(.defaultAction)
        }
    }.padding(20)
    .onAppear { retrySelection = Set(r.retryableFailures.map { $0.item.destRelPath }) }   // default-on retryable
}
```
For `FaceLikeThumb`: reuse the existing thumbnail loader. Simplest = a tiny wrapper around `ThumbnailImage` keyed by the asset hash (the same component the timeline uses); if its API needs a different identifier, load via `state.library?.thumbnails.cachedDisplayImage(for: ContentHash(stringValue: hash), ...)` inside a small `@State` image view. Implement it as a minimal local view; thumbnails are an optional nicety (only when `showThumbs`).

- [ ] **Step 3: Wire the body** to choose confirm/running/finished from `state.syncActivity`. If `syncActivity == nil` → confirm (compute plan as today). Else switch on `phase`. The sheet is presented for `drive` (the root binding); when reopened during an active sync, `syncActivity` is already set so it shows progress directly.

- [ ] **Step 4: Build-verify + manual smoke**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Manual (dev machine): start a sync to a drive → progress shows GB/speed/ETA → **Minimize** returns to the app, sync continues → reopen via chip (Task 7) → **Cancel** stops within ~1s. Force a failure (e.g., unplug mid-sync) → failure report lists files + reasons → Retry.

- [ ] **Step 5: Commit**
```bash
git add Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
git commit -m "feat(app): sync sheet phases (progress/cancel/minimize) + failure report with retry"
```

---

## Task 7: Sidebar sync chip (App, build-verify)

**Files:**
- Modify: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`

- [ ] **Step 1: Add the chip** in the footer (right after the `derivationProgress` block, ~line 141), reading `state.syncActivity`:
```swift
if let a = state.syncActivity {
    Button {
        if let d = state.syncDrive { state.syncSheetDrive = d }
    } label: {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: a.phase == .running ? "arrow.triangle.2.circlepath" : "externaldrive.fill")
                Text(a.phase == .running ? "Syncing"
                     : (a.result?.failed.isEmpty == false ? "Sync finished" : "Synced"))
                    .font(.system(size: 11, weight: .medium))
            }.foregroundStyle(a.result?.retryableFailures.isEmpty == false ? Theme.amber : Theme.textDim)
            if a.phase == .running {
                ProgressView(value: Double(a.bytesDone), total: Double(max(a.bytesTotal, 1))).tint(Theme.accent)
                Text("\(byteString(a.bytesDone)) / \(byteString(a.bytesTotal)) · \(speedString(a.speedBytesPerSec))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textFaint)
            } else if let r = a.result, !r.retryableFailures.isEmpty {
                Text("\(r.retryableFailures.count) failed — tap to review")
                    .font(.system(size: 10)).foregroundStyle(Theme.amber)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 14).padding(.vertical, 6)
    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 10).padding(.bottom, 6)
}
```
Add the `byteString`/`speedString` helpers to `SidebarView` (or a shared `ByteFormat` util reused by the sheet + chip — preferred, DRY: create `Sources/OpenPhotoApp/Drives/ByteFormat.swift` with `byteString`, `speedString`, `etaString` free functions and use from both).

- [ ] **Step 2: Build-verify + manual** — chip appears while syncing; clicking reopens the sheet; after finish-with-failures it stays amber until Done.

- [ ] **Step 3: Commit**
```bash
git add Sources/OpenPhotoApp/Sidebar/SidebarView.swift Sources/OpenPhotoApp/Drives/ByteFormat.swift
git commit -m "feat(app): sidebar sync chip (live progress, reopen, failed badge)"
```

---

## Task 8: Full verification + local build

- [ ] **Step 1:** `swift test 2>&1 | tail -5` → all Core tests pass (existing + new VerifiedCopy/SyncApply/SyncRateMeter).
- [ ] **Step 2:** `swift build 2>&1 | grep -E "error:|Build complete"` → Build complete.
- [ ] **Step 3:** `./scripts/make-app.sh 2>&1 | tail -1` → Built build/OpenPhoto.app.
- [ ] **Step 4: Commit** any stragglers; done.

---

## Self-review checklist (author)

- Spec coverage: streaming copy+cancel (T1), bytes+cancel+classified failures+manifest-on-cancel (T2), speed/ETA (T3), AppState background activity + post-processing moved (T4), root sheet + minimize/reopen plumbing (T5), progress/cancel/minimize + failure report + retry (T6), sidebar chip (T7), verify+build (T8). ✓
- Types consistent: `CopyOutcome`, `SyncFailureReason`, `FailedItem`, `SyncProgress(+bytes)`, `SyncResult{failed:[FailedItem], cancelled, conflicts computed, retryableFailures}`, `SyncActivity`, `AppState.{syncActivity,syncSheetDrive,syncTask,syncDrive,syncCancelRequested}` + `startSync/cancelSync/retrySyncFailures/dismissSyncResult/finishSync`. ✓
- Safety preserved: atomic temp→fsync→rename, never-overwrite, manifest-on-cancel (resume), free-space guard. ✓
- Scope: Sync only; Send untouched. ✓
