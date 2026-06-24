# Evict / Rehydrate Storage Management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user move original media between the Mac and the canonical/backup drive — free up all Mac space, download everything back, or do either per-folder — as a single background job with progress, ETA, cancel, and a sidebar chip.

**Architecture:** Generalize the existing bespoke sync background job (`SyncActivity` + ticker + rate meter + cancel flag + chip + sheet) into one unified `DriveJob` (kind = sync | evict | rehydrate) with a single active slot, enforcing "only one job at a time". The dangerous core (`evict`/`rehydrate` in `LibraryService+Eviction.swift`) already exists and is hash-verified + Trash-based; we add default-nil progress/cancel callbacks to it, plus gather queries and UI entry points.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (`swift build` / `swift test`), swift-testing (`@Test`/`#expect`), SwiftUI, GRDB-backed catalog.

**Spec:** `docs/superpowers/specs/2026-06-24-evict-rehydrate-storage-design.md`

**Conventions in this codebase (read before starting):**
- Run tests with `swift test --filter <Name>`; build with `swift build`.
- `@Sendable` engine closures must NOT capture `self` or mutable vars — capture an independent value (see `SyncCancelFlag` and `weak var weakSelf` in `AppState+Sync.swift`).
- Tests that need a mutable value inside a `@Sendable` closure wrap it in `Box<T>: @unchecked Sendable` (see `Tests/OpenPhotoCoreTests/VerifiedCopyTests.swift`).
- Hashes are `"sha256:"+hex`; `ContentHash.ofFile(at:)` computes them. `VerifiedCopy.copy(from:to:expectedHash:chunkBytes:onBytes:shouldCancel:) -> CopyOutcome` (`.copied`/`.cancelled`/`.failed(SyncFailureReason)`) is the atomic, hash-verified, direction-agnostic copy primitive.
- `FailedItem { item: PlanItem, reason: SyncFailureReason }` lives in `Sources/OpenPhotoCore/Sync/SyncFailure.swift`. `PlanItem { hash, sourceURL, destRelPath, size }`. `SyncFailureReason` cases: `.sourceMissing, .copyFailed, .hashMismatch, .conflict` with `.userText` and `.isRetryable`.
- NEVER touch real user media in tests — use `FileManager.default.temporaryDirectory` + a `LibraryService` over a temp vault, exactly like `Tests/OpenPhotoCoreTests/SyncApplyTests.swift`.

---

## File structure

**Core (OpenPhotoCore):**
- Create `Sources/OpenPhotoCore/Storage/DriveProgress.swift` — the shared progress struct for evict/rehydrate (stage + file/byte counters).
- Modify `Sources/OpenPhotoCore/LibraryService+Eviction.swift` — add `failedItems` to `RehydrateOutcome`; add `progress`/`shouldCancel` to `evict` and `rehydrate`.
- Create `Sources/OpenPhotoCore/Storage/StorageQueries.swift` — `allEvictableLocal(canonicalPresence:)` and `allDriveOnly()` gather queries (extension on `LibraryService`).
- Tests: `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift`, `Tests/OpenPhotoCoreTests/StorageQueriesTests.swift`.

**App (OpenPhotoApp):**
- Modify `Sources/OpenPhotoApp/AppState+Sync.swift` — rename `SyncActivity` → `DriveJob` (add `kind`, `scopeLabel`, `DriveJobResult`); generalize start/finish/cancel/ticker; add `startEvictJob`/`startRehydrateJob`.
- Modify `Sources/OpenPhotoApp/AppState.swift` — rename the sync stored props to `job*`; add `resolveDrive(forHashes:)`, `evictableItems(_:)`, `allEvictableItems()`, `allDriveOnlyItems()` wrappers.
- Modify `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` → rename file+struct to `Sources/OpenPhotoApp/Drives/DriveJobSheet.swift` — generalize running/finished/failure views over `DriveJob.kind`.
- Modify `Sources/OpenPhotoApp/Drives/DrivesView.swift` — header `Free Up Mac Space…` / `Download All to Mac…` buttons + confirm + plug-in prompt; generalize the `syncing` gate to `jobRunning`.
- Modify `Sources/OpenPhotoApp/Folders/FolderTreeView.swift` — context-menu `Evict This Folder…` / `Download This Folder to Mac…`.
- Modify `Sources/OpenPhotoApp/Sidebar/SidebarView.swift` — chip reads `activeJob`, label varies by kind.
- Modify `Sources/OpenPhotoApp/OpenPhotoApp.swift` — `.sheet(item:)` uses the renamed sheet + drive slot.

---

## Task 1: Core — `DriveProgress` + `RehydrateOutcome.failedItems` + rehydrate progress/cancel

**Files:**
- Create: `Sources/OpenPhotoCore/Storage/DriveProgress.swift`
- Modify: `Sources/OpenPhotoCore/LibraryService+Eviction.swift`
- Test: `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift`

- [ ] **Step 1: Create the `DriveProgress` struct**

Create `Sources/OpenPhotoCore/Storage/DriveProgress.swift`:

```swift
import Foundation

/// Progress for a long storage operation (evict or rehydrate). Mirrors `SyncProgress` but with the
/// extra stages those operations use. The App buffers the latest one and a 0.5s ticker renders it
/// (windowed speed + whole-job ETA) — same pattern as sync.
public struct DriveProgress: Sendable {
    public enum Stage: String, Sendable { case verifying, copying, trashing, finishing }
    public var stage: Stage
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentName: String
    public init(stage: Stage, filesDone: Int = 0, filesTotal: Int = 0,
                bytesDone: Int64 = 0, bytesTotal: Int64 = 0, currentName: String = "") {
        self.stage = stage; self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.currentName = currentName
    }
}
```

- [ ] **Step 2: Write the failing test for rehydrate progress + cancel + failures**

Create `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift`. Use the same temp-vault harness as `SyncApplyTests.swift` (read that file first for the exact `LibraryService` setup helpers it uses — reuse them). The test rehydrates two drive-only items and asserts byte progress reaches the total and failures are named:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func rehydrateReportsByteProgressAndNamesFailures() async throws {
    // Build a Mac vault + a connected drive holding two originals the Mac lacks (drive-only).
    let h = try StorageTestHarness.make()                 // see Step 3 — add this helper
    let items = try h.makeDriveOnly(count: 2, sizeEach: 1_000_000)

    final class Box: @unchecked Sendable { var last: DriveProgress?; var maxBytes: Int64 = 0 }
    let box = Box()
    let outcome = try await h.lib.rehydrate(items, connectedCanonical: [h.drive],
        progress: { p in box.last = p; box.maxBytes = max(box.maxBytes, p.bytesDone) },
        shouldCancel: nil)

    #expect(outcome.rehydrated == 2)
    #expect(outcome.failedItems.isEmpty)
    #expect(box.maxBytes == 2_000_000)                    // byte bar reached the total
    #expect(box.last?.stage == .copying)
}

@Test func rehydrateCancelStopsEarly() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeDriveOnly(count: 3, sizeEach: 1_000_000)
    let outcome = try await h.lib.rehydrate(items, connectedCanonical: [h.drive],
        progress: nil, shouldCancel: { true })            // cancel immediately
    #expect(outcome.rehydrated == 0)
}
```

- [ ] **Step 3: Add a shared test harness for storage tests**

Add to the top of `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift` a `StorageTestHarness` that builds a `LibraryService` over a temp Mac vault + a temp drive vault, writes N originals into the drive, registers the drive's `vault_presence`, and returns `TimelineItem`s that are drive-only (present on the drive, absent on the Mac). Model it exactly on how `SyncApplyTests.swift` constructs its `LibraryService`, vaults, and manifests (open that file and copy its setup verbatim, adapting paths). The harness exposes `lib: LibraryService`, `drive: Vault`, `makeDriveOnly(count:sizeEach:) throws -> [TimelineItem]`, and (for Task 2) `makeLocalBackedUp(count:sizeEach:) throws -> [TimelineItem]`. Implement `makeDriveOnly` by: writing each file into the drive root under `Pictures/op_<i>.jpg`, hashing it, inserting a `vault_presence` row (`hash, relPath: "op_<i>.jpg", dirPath: "", size, driveRelPath: "Pictures/op_<i>.jpg"`) via the same catalog API `refreshCanonicalPresence`/`replaceVaultPresence` uses, and building a `TimelineItem` with `driveRelPath` set (look at `Catalog.instanceItem`/`vaultPresenceRows` and `Records.swift` `TimelineItem` for the exact field list).

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test --filter EvictRehydrateProgressTests`
Expected: FAIL — `rehydrate` has no `progress:`/`shouldCancel:` params and `RehydrateOutcome` has no `failedItems`.

- [ ] **Step 5: Add `failedItems` to `RehydrateOutcome`**

In `Sources/OpenPhotoCore/LibraryService+Eviction.swift` replace the `RehydrateOutcome` struct (lines 14-18):

```swift
public struct RehydrateOutcome: Sendable, Equatable {
    public var rehydrated: Int
    public var failedItems: [FailedItem]
    public var failed: Int { failedItems.count }
    public init(rehydrated: Int = 0, failedItems: [FailedItem] = []) {
        self.rehydrated = rehydrated; self.failedItems = failedItems
    }
}
```

- [ ] **Step 6: Thread progress + cancel into `rehydrate`**

Replace the `rehydrate(_:connectedCanonical:)` signature and body (lines 74-116) with the version below. Changes: new default-nil `progress`/`shouldCancel`; `bytesTotal` = sum of item sizes; per-item progress + cancel check; `onBytes` threaded into `VerifiedCopy.copy`; failures recorded as `FailedItem`.

```swift
@discardableResult
public func rehydrate(_ items: [TimelineItem], connectedCanonical: [Vault],
                      progress: (@Sendable (DriveProgress) -> Void)? = nil,
                      shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> RehydrateOutcome {
    var outcome = RehydrateOutcome()
    var restoredPerVault: [String: Int] = [:]
    let targets = items.filter { $0.driveRelPath != nil }
    let bytesTotal = targets.reduce(Int64(0)) { $0 + $1.size }
    var bytesDone: Int64 = 0
    for (i, item) in targets.enumerated() {
        if shouldCancel?() == true { break }
        let name = (item.relPath as NSString).lastPathComponent
        let base = bytesDone
        progress?(DriveProgress(stage: .copying, filesDone: i, filesTotal: targets.count,
                                bytesDone: base, bytesTotal: bytesTotal, currentName: name))
        func fail(_ reason: SyncFailureReason) {
            outcome.failedItems.append(FailedItem(
                item: PlanItem(hash: item.hash, sourceURL: URL(fileURLWithPath: item.relPath),
                               destRelPath: item.relPath, size: item.size), reason: reason))
            bytesDone += item.size
        }
        guard let (drive, stillRow) = driveSource(forHash: item.hash, among: connectedCanonical)
        else { fail(.sourceMissing); continue }
        var halves: [(hash: String, driveRelPath: String, relPath: String)] =
            [(item.hash, stillRow.driveRelPath, item.relPath)]
        if let pairHash = item.livePairHash,
           let row = (try? catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                .first(where: { $0.hash == pairHash }) {
            halves.append((pairHash, row.driveRelPath, row.relPath))
        }
        var stillVaultID: String?
        var hadError = false
        for half in halves {
            guard let (local, localRel) = localTarget(forDriveRelPath: half.driveRelPath, macRelPath: half.relPath)
            else { continue }
            let dest = local.absoluteURL(forRelativePath: localRel)
            if FileManager.default.fileExists(atPath: dest.path) {
                if half.hash == item.hash { stillVaultID = local.descriptor.vaultID }
                continue
            }
            let outcome2 = VerifiedCopy.copy(
                from: drive.absoluteURL(forRelativePath: half.driveRelPath), to: dest,
                expectedHash: half.hash,
                onBytes: { fileBytes in
                    progress?(DriveProgress(stage: .copying, filesDone: i, filesTotal: targets.count,
                                            bytesDone: base + fileBytes, bytesTotal: bytesTotal,
                                            currentName: name))
                },
                shouldCancel: { shouldCancel?() == true })
            switch outcome2 {
            case .copied: if half.hash == item.hash { stillVaultID = local.descriptor.vaultID }
            case .cancelled: hadError = true
            case .failed: hadError = true
            }
        }
        bytesDone += item.size
        if let vid = stillVaultID, !hadError {
            outcome.rehydrated += 1; restoredPerVault[vid, default: 0] += 1
        } else if !(shouldCancel?() == true) {
            outcome.failedItems.append(FailedItem(
                item: PlanItem(hash: item.hash, sourceURL: drive.absoluteURL(forRelativePath: stillRow.driveRelPath),
                               destRelPath: item.relPath, size: item.size), reason: .copyFailed))
        }
    }
    for (vid, n) in restoredPerVault {
        if let v = vault(id: vid) {
            appendSyncLog(vault: v, event: "rehydrate", summary: "\(n) restored", counterpartyKey: "")
        }
        try await rescan(vaultID: vid)
    }
    return outcome
}
```

> Note: `bytesDone += item.size` happens exactly once per item (in `fail()` for early failures, or after the halves loop for the success/partial path). Do not double-count.

- [ ] **Step 7: Run the test to verify it passes**

Run: `swift test --filter EvictRehydrateProgressTests`
Expected: PASS (both rehydrate tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenPhotoCore/Storage/DriveProgress.swift Sources/OpenPhotoCore/LibraryService+Eviction.swift Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift
git commit -m "feat(core): rehydrate progress/cancel + named failures + DriveProgress"
```

---

## Task 2: Core — evict progress + cancel

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService+Eviction.swift`
- Test: `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift`:

```swift
@Test func evictReportsSizeWeightedProgressAndCancels() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeLocalBackedUp(count: 3, sizeEach: 1_000_000)   // local + verified on drive

    final class Box: @unchecked Sendable { var maxBytes: Int64 = 0; var lastFiles = 0 }
    let box = Box()
    let outcome = try await h.lib.evict(items, mode: .verified,
        connectedCanonical: [h.drive], canonicalPresence: [],
        progress: { p in box.maxBytes = max(box.maxBytes, p.bytesDone); box.lastFiles = p.filesDone },
        shouldCancel: nil)

    #expect(outcome.evicted == 3)
    #expect(outcome.refused == 0)
    #expect(box.maxBytes == 3_000_000)              // size-weighted bar reached the total
}

@Test func evictCancelStopsAndKeepsRemaining() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeLocalBackedUp(count: 3, sizeEach: 1_000_000)
    let outcome = try await h.lib.evict(items, mode: .verified,
        connectedCanonical: [h.drive], canonicalPresence: [],
        progress: nil, shouldCancel: { true })       // cancel immediately
    #expect(outcome.evicted == 0)                    // nothing trashed
}
```

`makeLocalBackedUp(count:sizeEach:)` (added to the harness in Task 1 Step 3): writes each original into BOTH the Mac vault and the drive (same bytes/hash), inserts a local `instances` row + a drive `vault_presence` row, and returns local `TimelineItem`s (`driveRelPath == nil`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter evictReportsSizeWeightedProgressAndCancels`
Expected: FAIL — `evict` has no `progress:`/`shouldCancel:` params.

- [ ] **Step 3: Thread progress + cancel into `evict`**

In `Sources/OpenPhotoCore/LibraryService+Eviction.swift`, change the `evict` signature (lines 26-28) to add the two params, and instrument the loop. Replace lines 26-68 with:

```swift
@discardableResult
public func evict(_ items: [TimelineItem], mode: EvictMode,
                  connectedCanonical: [Vault], canonicalPresence: Set<String>,
                  progress: (@Sendable (DriveProgress) -> Void)? = nil,
                  shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> EvictOutcome {
    let local = items.filter { $0.driveRelPath == nil }
    let bytesTotal = local.reduce(Int64(0)) { $0 + $1.size }
    var bytesDone: Int64 = 0
    var filesDone = 0
    var byVault: [String: [TimelineItem]] = [:]
    for it in local { byVault[it.vaultID, default: []].append(it) }
    var outcome = EvictOutcome()
    for (vaultID, group) in byVault {
        guard let localVault = vault(id: vaultID) else { continue }
        var releasedHere = 0
        for item in group {
            if shouldCancel?() == true {
                if releasedHere > 0 {
                    appendSyncLog(vault: localVault, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
                    try await rescan(vaultID: vaultID)
                }
                return outcome
            }
            let name = (item.relPath as NSString).lastPathComponent
            progress?(DriveProgress(stage: .verifying, filesDone: filesDone, filesTotal: local.count,
                                    bytesDone: bytesDone, bytesTotal: bytesTotal, currentName: name))
            var halves: [(hash: String, relPath: String)] = [(item.hash, item.relPath)]
            if let pairHash = item.livePairHash,
               let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                halves.append((pairHash, pairInstance.relPath))
            }
            defer { bytesDone += item.size; filesDone += 1 }
            guard halves.allSatisfy({ verifyOnCanonical(hash: $0.hash, mode: mode,
                                                        connectedCanonical: connectedCanonical,
                                                        canonicalPresence: canonicalPresence) })
            else { outcome.refused += 1; continue }
            let stillURL = localVault.absoluteURL(forRelativePath: item.relPath)
            try? FileManager.default.trashItem(at: stillURL, resultingItemURL: nil)
            guard !FileManager.default.fileExists(atPath: stillURL.path) else {
                outcome.refused += 1; continue
            }
            outcome.evicted += 1; releasedHere += 1
            if halves.count > 1 {
                try? FileManager.default.trashItem(
                    at: localVault.absoluteURL(forRelativePath: halves[1].relPath), resultingItemURL: nil)
            }
        }
        if releasedHere > 0 {
            appendSyncLog(vault: localVault, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
            try await rescan(vaultID: vaultID)
        }
    }
    return outcome
}
```

> The `defer` increments byte/file counters once per item regardless of refuse/evict, so the bar advances smoothly and `filesDone` tracks processed items. Cancel is checked at the top of each item (before any trash), so a cancelled job never leaves a half-processed file; already-evicted items in the current vault still get their rescan.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EvictRehydrateProgressTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Verify existing callers still compile**

Run: `swift build`
Expected: Build complete. (The new params are default-nil, so `AppState.evict`/`rehydrate` and the Inspector are unaffected. If `RehydrateOutcome.failed` is referenced as a stored property anywhere it now reads the computed var — confirm with `grep -rn "\.failed" Sources/OpenPhotoApp | grep -i rehydr`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/LibraryService+Eviction.swift Tests/OpenPhotoCoreTests/EvictRehydrateProgressTests.swift
git commit -m "feat(core): evict progress + cancel (size-weighted, cancel-safe)"
```

---

## Task 3: Core — gather queries

**Files:**
- Create: `Sources/OpenPhotoCore/Storage/StorageQueries.swift`
- Test: `Tests/OpenPhotoCoreTests/StorageQueriesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/StorageQueriesTests.swift` (reuse `StorageTestHarness` from Task 1 — move it to its own file `Tests/OpenPhotoCoreTests/StorageTestHarness.swift` so both test files share it; do that move as the first action here and update Task 1's file to `import`/rely on the shared harness):

```swift
import Testing
@testable import OpenPhotoCore

@Test func gatherQueriesPartitionLocalAndDriveOnly() async throws {
    let h = try StorageTestHarness.make()
    let localItems = try h.makeLocalBackedUp(count: 2, sizeEach: 1000)   // present on Mac + drive
    let driveOnly = try h.makeDriveOnly(count: 3, sizeEach: 1000)        // drive only

    let presence = Set(localItems.map(\.hash))   // the 2 local items are "backed up"
    let evictable = try h.lib.allEvictableLocal(canonicalPresence: presence)
    let onlyOnDrive = try h.lib.allDriveOnly()

    #expect(Set(evictable.map(\.hash)) == Set(localItems.map(\.hash)))
    #expect(Set(onlyOnDrive.map(\.hash)) == Set(driveOnly.map(\.hash)))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter gatherQueriesPartitionLocalAndDriveOnly`
Expected: FAIL — `allEvictableLocal`/`allDriveOnly` don't exist.

- [ ] **Step 3: Implement the queries**

Create `Sources/OpenPhotoCore/Storage/StorageQueries.swift`. Read `Sources/OpenPhotoCore/Catalog/Queries.swift` first to reuse the existing local-instances and drive-only enumeration the folder tree already uses (`folderCounts`/`items(inDir:)`), then implement:

```swift
import Foundation

extension LibraryService {
    /// Every local original whose hash is verified-present on a durable drive — the evict-all set.
    public func allEvictableLocal(canonicalPresence: Set<String>) throws -> [TimelineItem] {
        try catalog.allLocalInstances().filter { $0.driveRelPath == nil && canonicalPresence.contains($0.hash) }
    }
    /// Every asset present on a drive but absent from the Mac — the rehydrate-all set.
    public func allDriveOnly() throws -> [TimelineItem] {
        try catalog.allDriveOnlyItems()
    }
}
```

If `catalog.allLocalInstances()` / `catalog.allDriveOnlyItems()` don't already exist, add them in `Sources/OpenPhotoCore/Catalog/Queries.swift` next to the existing folder-grouping queries, returning `[TimelineItem]` — `allLocalInstances` selects every row from `instances` (mapped to `TimelineItem` with `driveRelPath == nil`); `allDriveOnlyItems` selects every `vault_presence` row whose `hash` is NOT in `instances` (the same predicate the folder tree uses to surface drive-only assets — copy that SQL). Match the existing `TimelineItem` construction in that file exactly.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter StorageQueriesTests`
Expected: PASS.

- [ ] **Step 5: Run the full core suite (no regressions)**

Run: `swift test --filter "Sync|Evict|Rehydrate|Storage|VerifiedCopy"`
Expected: all PASS, including the pre-existing `SyncApplyTests`, `SyncRateMeterTests`, `VerifiedCopyTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Storage/StorageQueries.swift Sources/OpenPhotoCore/Catalog/Queries.swift Tests/OpenPhotoCoreTests/StorageQueriesTests.swift Tests/OpenPhotoCoreTests/StorageTestHarness.swift
git commit -m "feat(core): allEvictableLocal + allDriveOnly gather queries"
```

---

## Task 4: App — generalize `SyncActivity` → `DriveJob` (compile-only refactor)

This task ONLY renames + generalizes the existing sync job so everything still compiles and the sync still works. No evict/rehydrate behavior yet.

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState+Sync.swift`
- Modify: `Sources/OpenPhotoApp/AppState.swift` (stored props + teardown)
- Modify: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`
- Modify: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift`

- [ ] **Step 1: Replace `SyncActivity` with `DriveJob`**

In `Sources/OpenPhotoApp/AppState+Sync.swift`, replace the `SyncActivity` struct (lines 4-17) with:

```swift
/// Observable snapshot of an in-flight (or just-finished) background drive job — a sync, an evict,
/// or a rehydrate. The sheet + sidebar chip read this; `AppState.activeJob` is the single source of
/// truth (only ONE job runs at a time), updated on the MainActor.
struct DriveJob: Sendable {
    enum Kind: String, Sendable { case sync, evict, rehydrate }
    enum Phase: Sendable, Equatable { case running, finished, cancelled }
    var kind: Kind
    var scopeLabel: String                      // "all photos", a folder name — for display
    var driveName: String
    var stage: DriveProgress.Stage
    var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    var filesDone = 0, filesTotal = 0
    var currentName = ""
    var speedBytesPerSec = 0.0
    var etaSeconds: Double?
    var phase: Phase = .running
    var result: DriveJobResult?                 // set when phase != .running
}

enum DriveJobResult: Sendable {
    case sync(SyncResult)
    case evict(EvictOutcome)
    case rehydrate(done: Int, failed: [FailedItem])
}
```

Rename `SyncCancelFlag` → keep the class but rename to `JobCancelFlag` (same body). Update its doc comment to say "background job" instead of "sync".

- [ ] **Step 2: Map `SyncProgress.Stage` → `DriveProgress.Stage` in the sync path**

The sync engine emits `SyncProgress` (stages `.copying/.verifying/.finishing`). `DriveJob.stage` is a `DriveProgress.Stage`. Add a tiny mapper near the top of `AppState+Sync.swift`:

```swift
private extension SyncProgress.Stage {
    var asDriveStage: DriveProgress.Stage {
        switch self { case .copying: .copying; case .verifying: .verifying; case .finishing: .finishing }
    }
}
```

(If `SyncProgress.Stage` has different/more cases, map them all — open `Sources/OpenPhotoCore/Sync/SyncPlan.swift` to confirm the case list.)

- [ ] **Step 3: Rename the stored properties in `AppState.swift`**

In `Sources/OpenPhotoApp/AppState.swift`, rename the sync job stored props (around lines 91-114 and teardown ~1979). Apply this exact mapping everywhere in the file:

| old | new |
|---|---|
| `syncActivity: SyncActivity?` | `activeJob: DriveJob?` |
| `syncSheetDrive: Vault?` | `jobSheetDrive: Vault?` |
| `syncTask` | `jobTask` |
| `syncCancelRequested` | `jobCancelRequested` |
| `syncCancelFlag: SyncCancelFlag?` | `jobCancelFlag: JobCancelFlag?` |
| `syncDrive: Vault?` | `jobDrive: Vault?` |
| `syncRateMeter` | `jobRateMeter` |
| `syncRaw: SyncProgress?` | `jobRaw: DriveProgress?` |
| `syncTickerTask` | `jobTickerTask` |

Add a computed helper near these props:

```swift
var jobRunning: Bool { activeJob?.phase == .running }
```

- [ ] **Step 4: Update `AppState+Sync.swift` to the new names + `DriveProgress`**

Rewrite `startSync`/`finishSync`/`cancelSync`/`retrySyncFailures`/`dismissSyncResult` using the renamed props. Key changes: `activeJob = DriveJob(kind: .sync, scopeLabel: "", driveName: …, stage: .copying, bytesTotal:…, filesTotal:…)`; the engine `progress:` closure buffers into `jobRaw` as a `DriveProgress` (`weakSelf?.jobRaw = DriveProgress(stage: p.stage.asDriveStage, filesDone: p.done, filesTotal: p.total, bytesDone: p.bytesDone, bytesTotal: p.bytesTotal, currentName: p.currentName)`); the ticker reads `jobRaw` (already a `DriveProgress`, so use its fields directly — `a.stage = raw.stage`, `a.filesDone = raw.filesDone`); `finishSync` sets `a.result = .sync(r)`; `a.stage = .finishing` for the finishing state. `dismissSyncResult` clears `activeJob`, `jobDrive`, `jobSheetDrive`. Keep all the recent fixes (finishing state, `done: i+1` already lives in the engine, the `await Task.yield()`).

Show the full rewritten `startSync` header so the engine `done` field maps correctly (`SyncProgress.done` → `DriveProgress.filesDone`):

```swift
syncTickerTask_REMOVE   // (delete; renamed below)
jobTickerTask = Task { @MainActor in
    while !Task.isCancelled {
        if let self = weakSelf, let raw = self.jobRaw,
           var a = self.activeJob, a.phase == .running {
            let (speed, eta) = self.jobRateMeter.update(
                bytesDone: raw.bytesDone, bytesTotal: bytesTotal, now: Date().timeIntervalSince(start))
            a.bytesDone = raw.bytesDone; a.filesDone = raw.filesDone
            a.currentName = raw.currentName; a.stage = raw.stage
            a.speedBytesPerSec = speed; a.etaSeconds = eta
            self.activeJob = a
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
```

- [ ] **Step 5: Update the sheet, chip, DrivesView, and OpenPhotoApp to the new names**

- `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift`: replace `state.syncActivity` → `state.activeJob`; the `if let a = state.syncActivity` switch now reads `a.phase`/`a.kind`. For this task keep the views sync-only in behavior (Task 7 generalizes them); just make `a.result` access go through `if case .sync(let r) = a.result`. Replace `state.cancelSync()`/`state.dismissSyncResult()` calls as-is (names unchanged). `isRunning` uses `state.activeJob?.phase == .running`.
- `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`: chip reads `state.activeJob` instead of `syncActivity`; reopen sets `state.jobSheetDrive = state.jobDrive`. Keep the label "Syncing" for now (Task 8 varies it by kind).
- `Sources/OpenPhotoApp/Drives/DrivesView.swift`: change `private var syncing: Bool { state.syncActivity?.phase == .running }` → `private var syncing: Bool { state.jobRunning }` (leave the `.disabled(... || syncing)` call sites as-is).
- `Sources/OpenPhotoApp/OpenPhotoApp.swift`: `.sheet(item: $state.syncSheetDrive)` → `.sheet(item: $state.jobSheetDrive)`.

- [ ] **Step 6: Build and run the sync tests**

Run: `swift build && swift test --filter "SyncApply|SyncRateMeter|VerifiedCopy|EvictRehydrate|StorageQueries"`
Expected: Build complete; all tests pass. The sync UI is unchanged in behavior; only names changed.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(app): generalize SyncActivity -> DriveJob (one job slot)"
```

---

## Task 5: App — `startEvictJob` / `startRehydrateJob` + generalized finish

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState+Sync.swift` (or a new `Sources/OpenPhotoApp/AppState+StorageJobs.swift`)

- [ ] **Step 1: Add `startRehydrateJob` and `startEvictJob`**

Create `Sources/OpenPhotoApp/AppState+StorageJobs.swift`. Both mirror `startSync`: guard `jobTask == nil`, set up the cancel flag + rate meter + `jobRaw = nil`, create `activeJob` with the right `kind`/`scopeLabel`/totals, start the SAME ticker (extract the ticker into a private `startJobTicker(start:bytesTotal:)` helper reused by all three starts to stay DRY), and run a `jobTask` that calls the core function with `progress:` (buffering into `jobRaw`) + `shouldCancel:` (the flag), then a `finishStorageJob`.

```swift
import SwiftUI
import OpenPhotoCore

extension AppState {
    func startRehydrateJob(items: [TimelineItem], scopeLabel: String, driveName: String) {
        guard jobTask == nil, let lib = library else { return }
        let drives = connectedDrivesCanonicalFirst()
        jobCancelRequested = false
        let flag = JobCancelFlag(); jobCancelFlag = flag
        jobRateMeter = SyncRateMeter(); jobRaw = nil
        let bytesTotal = items.reduce(Int64(0)) { $0 + $1.size }
        activeJob = DriveJob(kind: .rehydrate, scopeLabel: scopeLabel, driveName: driveName,
                             stage: .copying, bytesTotal: bytesTotal, filesTotal: items.count)
        let start = Date(); startJobTicker(start: start, bytesTotal: bytesTotal)
        weak var weakSelf = self
        jobTask = Task {
            let outcome = (try? await lib.rehydrate(items, connectedCanonical: drives,
                progress: { p in Task { @MainActor in weakSelf?.jobRaw = p } },
                shouldCancel: { flag.isCancelled })) ?? RehydrateOutcome()
            await weakSelf?.finishStorageJob(
                result: .rehydrate(done: outcome.rehydrated, failed: outcome.failedItems),
                cancelled: flag.isCancelled)
        }
    }

    func startEvictJob(items: [TimelineItem], scopeLabel: String, driveName: String) {
        guard jobTask == nil, let lib = library else { return }
        let drives = connectedDrivesCanonicalFirst(); let presence = canonicalPresence
        jobCancelRequested = false
        let flag = JobCancelFlag(); jobCancelFlag = flag
        jobRateMeter = SyncRateMeter(); jobRaw = nil
        let bytesTotal = items.reduce(Int64(0)) { $0 + $1.size }
        activeJob = DriveJob(kind: .evict, scopeLabel: scopeLabel, driveName: driveName,
                             stage: .verifying, bytesTotal: bytesTotal, filesTotal: items.count)
        let start = Date(); startJobTicker(start: start, bytesTotal: bytesTotal)
        weak var weakSelf = self
        jobTask = Task {
            let outcome = (try? await lib.evict(items, mode: .verified, connectedCanonical: drives,
                canonicalPresence: presence,
                progress: { p in Task { @MainActor in weakSelf?.jobRaw = p } },
                shouldCancel: { flag.isCancelled })) ?? EvictOutcome()
            await weakSelf?.finishStorageJob(result: .evict(outcome), cancelled: flag.isCancelled)
        }
    }

    @MainActor private func finishStorageJob(result: DriveJobResult, cancelled: Bool) async {
        jobTickerTask?.cancel(); jobTickerTask = nil
        guard library != nil else { jobTask = nil; jobCancelFlag = nil; jobRaw = nil; return }
        // Refresh presence + library so the Timeline reflects the new local/drive-only states.
        reloadCanonicalPresence()
        await reloadLibraryAfterStorageChange()     // see Step 2
        var a = activeJob ?? DriveJob(kind: .evict, scopeLabel: "", driveName: "", stage: .finishing)
        a.phase = cancelled ? .cancelled : .finished
        if !cancelled { a.bytesDone = a.bytesTotal; a.filesDone = a.filesTotal }
        a.result = result
        activeJob = a
        jobTask = nil; jobCancelFlag = nil; jobRaw = nil
    }
}
```

- [ ] **Step 2: Add the ticker helper + the post-job reload**

Extract the ticker from `startSync` into a reusable private helper on `AppState` (in `AppState+Sync.swift`), and add `reloadLibraryAfterStorageChange()`:

```swift
@MainActor func startJobTicker(start: Date, bytesTotal: Int64) {
    weak var weakSelf = self
    jobTickerTask = Task { @MainActor in
        while !Task.isCancelled {
            if let self = weakSelf, let raw = self.jobRaw,
               var a = self.activeJob, a.phase == .running {
                let (speed, eta) = self.jobRateMeter.update(
                    bytesDone: raw.bytesDone, bytesTotal: bytesTotal, now: Date().timeIntervalSince(start))
                a.bytesDone = raw.bytesDone; a.filesDone = raw.filesDone
                a.currentName = raw.currentName; a.stage = raw.stage
                a.speedBytesPerSec = speed; a.etaSeconds = eta
                self.activeJob = a
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
```

Make `startSync` call `startJobTicker(start:bytesTotal:)` instead of its inline ticker (DRY). For `reloadLibraryAfterStorageChange()`, reuse whatever the app already calls after a delete/evict to refresh the Timeline — find it by `grep -n "func reload\|loadTimeline\|refreshTimeline\|reloadAll" Sources/OpenPhotoApp/AppState*.swift` and call the same path the Inspector evict uses after `state.evict`. If the Inspector relies on the catalog observation to refresh automatically, this can be a no-op; verify by reading how `state.evict` is consumed.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete. (No new tests — these are App orchestration methods exercised by the UI in later tasks and Jude's smoke.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(app): startEvictJob/startRehydrateJob on the unified job slot"
```

---

## Task 6: App — drive resolution + item-gathering wrappers

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (or `AppState+StorageJobs.swift`)

- [ ] **Step 1: Add `DriveAvailability` + `resolveDrive`**

Add to `AppState+StorageJobs.swift`:

```swift
enum DriveAvailability { case ready([Vault]); case needsDrive(name: String); case nothingToDo }

extension AppState {
    /// Decide whether a storage op can run now. If any durable drive is connected, proceed (the core
    /// op processes what those drives can serve and reports the rest). If none is connected, name the
    /// registered drive that holds the most of these hashes so we can prompt the user to plug it in.
    func resolveDrive(forHashes hashes: Set<String>) -> DriveAvailability {
        if hashes.isEmpty { return .nothingToDo }
        let connected = connectedDrivesCanonicalFirst()
        if !connected.isEmpty { return .ready(connected) }
        var best: (name: String, n: Int)?
        for vr in durableVaults {
            guard let hs = try? library?.catalog.vaultPresenceHashes(forVault: vr.id) else { continue }
            let n = hashes.intersection(hs).count
            if n > (best?.n ?? 0) { best = ((vr.rootPath as NSString).lastPathComponent, n) }
        }
        return .needsDrive(name: best?.name ?? "your drive")
    }
}
```

- [ ] **Step 2: Add item-gathering wrappers + `evictableItems`**

```swift
extension AppState {
    func allEvictableItems() -> [TimelineItem] {
        (try? library?.allEvictableLocal(canonicalPresence: canonicalPresence)) ?? []
    }
    func allDriveOnlyItems() -> [TimelineItem] {
        (try? library?.allDriveOnly()) ?? []
    }
    /// Local, backed-up subset of a given set (folder evict).
    func evictableItems(_ items: [TimelineItem]) -> [TimelineItem] {
        items.filter { $0.driveRelPath == nil && canonicalPresence.contains($0.hash) }
    }
    /// Items under a folder (recursive) split for the two operations.
    func folderEvictable(dirPath: String) -> [TimelineItem] {
        let items = (try? library?.items(inDir: dirPath, vaultID: nil, recursive: true)) ?? []
        return evictableItems(items)
    }
    func folderRehydratable(dirPath: String) -> [TimelineItem] {
        let items = (try? library?.items(inDir: dirPath, vaultID: nil, recursive: true)) ?? []
        return rehydratableItems(items)     // existing helper
    }
}
```

Confirm `rehydratableItems(_:)` exists and returns drive-only items (`grep -n "func rehydratableItems" Sources/OpenPhotoApp/AppState*.swift`). If its filter differs, match `folderRehydratable` to it.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(app): drive resolution + evict/rehydrate item gathering"
```

---

## Task 7: App — generalize the job sheet (running / finished / failure for all kinds)

**Files:**
- Rename: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` → `Sources/OpenPhotoApp/Drives/DriveJobSheet.swift`
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift` (sheet construction)

- [ ] **Step 1: Rename the file + struct**

`git mv Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift Sources/OpenPhotoApp/Drives/DriveJobSheet.swift` and rename `struct SyncPlanSheet` → `struct DriveJobSheet`. Update the construction site in `OpenPhotoApp.swift` (`SyncPlanSheet(state:…, drive:…)` → `DriveJobSheet(state:…, drive:…)`).

- [ ] **Step 2: Make the running view kind-aware**

In `DriveJobSheet.runningView(_ a: DriveJob)`, vary the title/labels by `a.kind` and `a.stage`. Replace the verb everywhere ("Copying") with a per-kind verb, and keep the existing finishing/byte-bar/speed/ETA/Cancel/Minimize structure:

```swift
private func verb(_ a: DriveJob) -> String {
    switch a.kind {
    case .sync: return "Copying"
    case .evict: return "Verifying"
    case .rehydrate: return "Downloading"
    }
}
private func title(_ a: DriveJob) -> String {
    switch a.kind {
    case .sync: return "Sync to \(a.driveName)"
    case .evict: return "Free up Mac space\(a.scopeLabel.isEmpty ? "" : " · \(a.scopeLabel)")"
    case .rehydrate: return "Download to Mac\(a.scopeLabel.isEmpty ? "" : " · \(a.scopeLabel)")"
    }
}
```

In the running view's non-finishing branch use `"\(verb(a)) \(a.currentName) · \(a.filesDone)/\(a.filesTotal) files"`. In the finishing branch keep "Finishing — saving the catalog to the drive…" only for `.sync`; for `.evict`/`.rehydrate` there is no finishing stage, so that branch won't show. Header `Text` uses `title(a)` when `activeJob != nil`.

- [ ] **Step 3: Make the finished + failure views kind-aware**

`finishedView` switches on `a.result`:

```swift
@ViewBuilder private func finishedView(_ a: DriveJob) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(a.phase == .cancelled ? "\(title(a)) — cancelled" : finishedHeadline(a))
            .font(.system(size: 14, weight: .semibold))
        Text(finishedDetail(a)).font(.system(size: 12)).foregroundStyle(Theme.textDim)
        Spacer()
        HStack { Spacer(); Button("Done") { state.dismissSyncResult(); dismiss() }.keyboardShortcut(.defaultAction) }
    }.padding(24)
}
private func finishedHeadline(_ a: DriveJob) -> String {
    switch a.result {
    case .sync: return "Sync complete"
    case .evict: return "Freed up space"
    case .rehydrate: return "Download complete"
    case .none: return "Done"
    }
}
private func finishedDetail(_ a: DriveJob) -> String {
    switch a.result {
    case let .sync(r): return "\(r.copied) copied · \(r.skipped) already there · \(r.sidecarsWritten) sidecars"
    case let .evict(o): return "\(o.evicted) photos moved to Trash" + (o.refused > 0 ? " · \(o.refused) kept (couldn’t verify on the drive)" : "")
    case let .rehydrate(done, failed): return "\(done) photos downloaded" + (failed.isEmpty ? "" : " · \(failed.count) failed")
    case .none: return ""
    }
}
```

The failure list view (the `List(r.failed …)` with per-file Retry) is shown when the result carries failures. Generalize it to read `failedItems` from either a `.sync(SyncResult)` (`r.failed`) or `.rehydrate(_, failed)`. Extract `failures(of: a) -> [FailedItem]`:

```swift
private func failures(_ a: DriveJob) -> [FailedItem] {
    switch a.result {
    case let .sync(r): return r.failed
    case let .rehydrate(_, f): return f
    default: return []
    }
}
```

Show `failureView` when `!failures(a).isEmpty`. The Retry button: for `.sync` keep `state.retrySyncFailures(items, drive:)`; for `.rehydrate` call a new `state.retryRehydrateFailures(_:)` that re-gathers the `TimelineItem`s by hash (`failed.map(\.item.hash)` → look up via `library?.timelineItems(forHashes:)` or filter `allDriveOnlyItems()`) and calls `startRehydrateJob`. Add that method in `AppState+StorageJobs.swift`. Evict failures (`refused`) are NOT retryable — for `.evict` show the list read-only with no toggles (they were kept safe by design); gate the Retry button on `a.kind != .evict`.

- [ ] **Step 4: Keep the sync confirm path working**

The `planView` (sync plan preview) only renders when `state.activeJob == nil` (sync entry via the per-drive "Sync…" button sets `jobSheetDrive` before a job exists). Evict/rehydrate always open the sheet with `activeJob != nil`, so they skip `planView`. Verify the `body`'s branching: `if let a = state.activeJob { running/finished/failure } else if let plan { planView } else { ProgressView }`.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(app): generalize the job sheet over sync/evict/rehydrate"
```

---

## Task 8: App — sidebar chip varies by kind + opens the sheet

**Files:**
- Modify: `Sources/OpenPhotoApp/Sidebar/SidebarView.swift`

- [ ] **Step 1: Vary the chip label/icon by `activeJob.kind`**

Read the current chip block (it reads `state.activeJob` after Task 4). Set its label by kind: `.sync` → "Syncing", `.evict` → "Freeing space", `.rehydrate` → "Downloading", with the existing progress fraction (`bytesDone/bytesTotal`) and the amber failed badge when `activeJob.result` carries failures. Clicking the chip opens the sheet: `state.jobSheetDrive = state.jobDrive`. If `jobDrive` is nil for evict/rehydrate (they aren't tied to one drive), set `jobDrive` to the first connected durable vault in `startEvictJob`/`startRehydrateJob` so the chip has a drive to key the sheet on — OR change the sheet presentation to a `Bool`. Simplest: in both start methods, set `jobDrive = connectedDrivesCanonicalFirst().first` so the chip + `.sheet(item: $jobSheetDrive)` keep working unchanged.

- [ ] **Step 2: Build + visually confirm the chip compiles**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(app): sidebar chip reflects evict/rehydrate jobs"
```

---

## Task 9: App — Drives header buttons (Free Up Mac Space / Download All to Mac)

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

- [ ] **Step 1: Add the two header buttons + state**

In `DrivesView`, add `@State private var confirmEvictAll = false`, `@State private var plugInPrompt: String?` (drive name to prompt), and a small struct to carry a pending op. In `mainContent`'s header `HStack` (next to "Verify All Drives"), add:

```swift
Button("Free Up Mac Space\u{2026}") { prepareEvictAll() }
    .controlSize(.small).disabled(jobRunning || state.durableVaults.isEmpty)
Button("Download All to Mac\u{2026}") { prepareRehydrateAll() }
    .controlSize(.small).disabled(jobRunning || state.durableVaults.isEmpty)
```

Add `private var jobRunning: Bool { state.jobRunning }` (and change the existing `syncing` flag to alias it or replace usages).

- [ ] **Step 2: Implement the prepare/confirm/start flow**

```swift
@State private var evictAllItems: [TimelineItem] = []

private func prepareEvictAll() {
    let items = state.allEvictableItems()
    guard !items.isEmpty else { return }
    switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
    case .ready: evictAllItems = items; confirmEvictAll = true
    case .needsDrive(let name): plugInPrompt = name
    case .nothingToDo: break
    }
}
private func prepareRehydrateAll() {
    let items = state.allDriveOnlyItems()
    guard !items.isEmpty else { return }
    switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
    case .ready(let drives):
        state.startRehydrateJob(items: items, scopeLabel: "all photos",
                                driveName: drives.first?.rootURL.lastPathComponent ?? "")
        state.jobSheetDrive = state.jobDrive               // open the progress sheet
    case .needsDrive(let name): plugInPrompt = name
    case .nothingToDo: break
    }
}
```

- [ ] **Step 3: Add the confirm alert + plug-in dialog**

On `mainContent` (or `body`), add:

```swift
.alert("Free up space on this Mac?", isPresented: $confirmEvictAll) {
    Button("Cancel", role: .cancel) {}
    Button("Free Up Space", role: .destructive) {
        let bytes = evictAllItems.reduce(Int64(0)) { $0 + $1.size }
        _ = bytes
        state.startEvictJob(items: evictAllItems, scopeLabel: "all photos",
                            driveName: state.connectedDrivesCanonicalFirst().first?.rootURL.lastPathComponent ?? "")
        state.jobSheetDrive = state.jobDrive
    }
} message: {
    let n = evictAllItems.count
    let bytes = evictAllItems.reduce(Int64(0)) { $0 + $1.size }
    Text("Move \(n) original\(n == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) to the Trash. They stay on your drive and you can download them back anytime.")
}
.confirmationDialog("Plug in your drive", isPresented: Binding(
    get: { plugInPrompt != nil }, set: { if !$0 { plugInPrompt = nil } }),
    titleVisibility: .visible, presenting: plugInPrompt) { _ in
    Button("OK", role: .cancel) { plugInPrompt = nil }
} message: { name in
    Text("Plug in \u{201c}\(name)\u{201d} so OpenPhoto can move these photos. Then try again.")
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): Drives header — Free Up Mac Space / Download All to Mac"
```

---

## Task 10: App — folder context-menu evict/rehydrate

**Files:**
- Modify: `Sources/OpenPhotoApp/Folders/FolderTreeView.swift`

- [ ] **Step 1: Add the two menu items + their state**

In the existing folder context menu (around lines 206-237), after a `Divider()`, add items that act on the right-clicked `FolderNode` (`node.path` / `node.name`). Add `@State` to the view: `@State private var confirmEvictFolder: (name: String, items: [TimelineItem])?` and reuse a `@State private var plugInPrompt: String?`. Menu items:

```swift
Divider()
let evictable = state.folderEvictable(dirPath: node.path)
if !evictable.isEmpty {
    Button("Evict This Folder\u{2026}") { prepareEvictFolder(node, evictable) }
}
let rehydratable = state.folderRehydratable(dirPath: node.path)
if !rehydratable.isEmpty {
    Button("Download This Folder to Mac\u{2026}") { prepareRehydrateFolder(node, rehydratable) }
}
```

> If computing `folderEvictable`/`folderRehydratable` inline in the menu builder is too costly (it queries the catalog), instead show the items unconditionally and compute inside the prepare functions, no-oping when empty.

- [ ] **Step 2: Implement prepare functions (mirror the Drives header)**

```swift
private func prepareEvictFolder(_ node: FolderNode, _ items: [TimelineItem]) {
    switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
    case .ready: confirmEvictFolder = (node.name, items)
    case .needsDrive(let name): plugInPrompt = name
    case .nothingToDo: break
    }
}
private func prepareRehydrateFolder(_ node: FolderNode, _ items: [TimelineItem]) {
    switch state.resolveDrive(forHashes: Set(items.map(\.hash))) {
    case .ready(let drives):
        state.startRehydrateJob(items: items, scopeLabel: node.name,
                                driveName: drives.first?.rootURL.lastPathComponent ?? "")
        state.jobSheetDrive = state.jobDrive
    case .needsDrive(let name): plugInPrompt = name
    case .nothingToDo: break
    }
}
```

- [ ] **Step 3: Add the confirm + plug-in dialogs to the view**

Mirror Task 9 Step 3 but folder-scoped:

```swift
.alert("Evict “\(confirmEvictFolder?.name ?? "")”?", isPresented: Binding(
    get: { confirmEvictFolder != nil }, set: { if !$0 { confirmEvictFolder = nil } }),
    presenting: confirmEvictFolder) { ctx in
    Button("Cancel", role: .cancel) { confirmEvictFolder = nil }
    Button("Free Up Space", role: .destructive) {
        state.startEvictJob(items: ctx.items, scopeLabel: ctx.name,
                            driveName: state.connectedDrivesCanonicalFirst().first?.rootURL.lastPathComponent ?? "")
        state.jobSheetDrive = state.jobDrive; confirmEvictFolder = nil
    }
} message: { ctx in
    let bytes = ctx.items.reduce(Int64(0)) { $0 + $1.size }
    Text("Move \(ctx.items.count) original\(ctx.items.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) in this folder to the Trash. They stay on your drive — download them back anytime.")
}
.confirmationDialog("Plug in your drive", isPresented: Binding(
    get: { plugInPrompt != nil }, set: { if !$0 { plugInPrompt = nil } }),
    titleVisibility: .visible, presenting: plugInPrompt) { _ in
    Button("OK", role: .cancel) { plugInPrompt = nil }
} message: { name in
    Text("Plug in \u{201c}\(name)\u{201d} so OpenPhoto can move these photos. Then try again.")
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): folder context menu — evict / download this folder"
```

---

## Task 11: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all tests pass (Core unit tests; the App has no unit tests).

- [ ] **Step 2: Full build + universal app**

Run: `swift build && scripts/make-app.sh`
Expected: `Built build/OpenPhoto.app`.

- [ ] **Step 3: Manual smoke checklist (Jude, on real hardware)**

Confirm: (a) Drives header shows the two buttons, disabled while any job runs; (b) "Download All to Mac" with the drive unplugged prompts to plug in the named drive; (c) a rehydrate shows the chip + progress + ETA + Cancel + Minimize, and only one job can run at a time; (d) "Free Up Mac Space" shows the destructive confirm with exact counts, then runs the verified evict and the Timeline shows the photos as drive-only afterward; (e) right-clicking a folder offers Evict / Download for that folder and they scope correctly; (f) a sync still behaves exactly as before. Files always land in the Trash (recoverable), never hard-deleted.

- [ ] **Step 4: Commit any smoke fixes, then hand back for the v1.0.0 release.**

---

## Self-review notes

- **Spec coverage:** evict-all (Task 9), rehydrate-all (Task 9), per-folder both (Task 10), drive-detection prompt (Tasks 6/9/10), one-job-at-a-time (Task 4 single slot + `jobRunning` gates), background chip (Tasks 4/8), `.verified` evict (Task 5 hard-codes `mode: .verified`), failure reporting (Task 7), Core progress/cancel (Tasks 1-2), gather queries (Task 3), recursive folders (Task 6 `recursive: true`), destructive non-typed confirm (Tasks 9-10). All covered.
- **Data safety:** evict still goes through `verifyOnCanonical` (`.verified`) then `trashItem`; cancel checked before any trash; rehydrate uses `VerifiedCopy` (atomic, hash-verified). No hard deletes; no writes to drives during rehydrate.
- **No on-disk format change** → `docs/format/` untouched (consistent with the spec).
