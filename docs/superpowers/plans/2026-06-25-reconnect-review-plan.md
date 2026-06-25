# Reconnect Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Gate the silent auto-apply of offline drive ops behind a "Changes since last connect" review (propagate vs undo), fold in the fast "Check" scan, keep Sync + Verify unchanged with tooltips.

**Architecture:** Catalog holds the optimistic post-edit state; queued ops + pending deletions + drift are the diff. We add catalog/core primitives (presence reapply, local move-revert), stop auto-draining ops on reconnect/verify, and present one review sheet that reuses existing apply/restore/adopt actions.

**Tech Stack:** SwiftPM, GRDB catalog, swift-testing, SwiftUI (`@Observable @MainActor AppState`).

**Spec:** `docs/superpowers/specs/2026-06-25-reconnect-review-design.md`

**Invariant (airtight):** for any drive, `vault_presence == manifest + pending-ops-reapplied`. Every manifest-driven presence rebuild must re-apply pending ops.

---

### Task 1: Catalog — reapply pending ops to presence

Preserves optimistic offline moves across a manifest-driven presence rebuild. Catalog-only; never touches a drive or file.

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift` (near `rewriteVaultPresencePath`, ~line 554)
- Test: `Tests/OpenPhotoCoreTests/PendingOpsPresenceTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func cat(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}
private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}

@Test func reapplyPendingOpsPreservesOptimisticMoveAfterPresenceRebuild() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try cat(t)
    let h = "sha256:" + String(repeating: "e", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    // A pending offline move A/p.jpg -> B/p.jpg for this drive.
    try c.enqueueFolderOp(vaultID: "drv", op: "moveFile", src: "A/p.jpg", dst: "B/p.jpg")
    // Simulate a manifest-driven rebuild: presence comes back at the OLD location (manifest unchanged).
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "A/p.jpg", dirPath: "A", size: 1, driveRelPath: "Pictures/A/p.jpg")])
    #expect(try c.items(inDir: "A").count == 1)         // reverted to old (the bug we must fix)

    try c.reapplyPendingOpsToPresence(vaultID: "drv")

    // Optimistic move restored: A empty, B shows it once, driveRelPath followed.
    #expect(try c.items(inDir: "A").isEmpty)
    #expect(try c.items(inDir: "B").count == 1)
    let rows = try c.vaultPresenceRows(forVault: "drv")
    #expect(rows.first?.relPath == "B/p.jpg")
    #expect(rows.first?.driveRelPath == "Pictures/B/p.jpg")
}

@Test func reapplyFolderMoveRepathsAllFilesUnderIt() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try cat(t)
    let h = "sha256:" + String(repeating: "f", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    try c.enqueueFolderOp(vaultID: "drv", op: "rename", src: "Old", dst: "New")
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "Old/p.jpg", dirPath: "Old", size: 1, driveRelPath: "Pictures/Old/p.jpg")])

    try c.reapplyPendingOpsToPresence(vaultID: "drv")

    #expect(try c.items(inDir: "Old").isEmpty)
    #expect(try c.items(inDir: "New").count == 1)
}
```

- [ ] **Step 2: Run, verify it fails** — Run: `swift test --filter reapplyPendingOps` → FAIL ("no member reapplyPendingOpsToPresence").

- [ ] **Step 3: Implement** in `Catalog.swift`:

```swift
/// Re-apply the catalog-side (presence-only) effect of this drive's queued ops, oldest-first, so a
/// manifest-driven presence rebuild doesn't revert an optimistic offline move. NEVER touches the drive
/// or any file. No-op for ops that don't move presence rows (empty-folder create/delete).
public func reapplyPendingOpsToPresence(vaultID: String) throws {
    for op in try pendingFolderOps(forVault: vaultID) {
        switch op.op {
        case "moveFile":
            if let s = op.src, let d = op.dst {
                try rewriteVaultPresencePath(vaultID: vaultID, fromRelPath: s, toRelPath: d)
            }
        case "move", "rename":
            if let s = op.src, let d = op.dst { try rewriteVaultPresencePaths(fromDir: s, toDir: d) }
        default:
            continue   // create / delete: an empty folder has no presence rows
        }
    }
}
```

- [ ] **Step 4: Run, verify it passes** — Run: `swift test --filter reapplyPendingOps` → PASS.
- [ ] **Step 5: Commit** — `feat(core): Catalog.reapplyPendingOpsToPresence (preserve optimistic offline moves)`

---

### Task 2: Wire reapply into every presence rebuild

Make the invariant airtight: after any `replaceVaultPresence` for a drive, reapply its pending ops.

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` — `driftScan` (~1717) and `verifyAllConnected` (~1744)

- [ ] **Step 1:** In `driftScan`, immediately after the `replaceVaultPresence(...)` call (line 1717-1719) add:

```swift
try? lib.catalog.reapplyPendingOpsToPresence(vaultID: driveVault.descriptor.vaultID)
```

- [ ] **Step 2:** In `verifyAllConnected`, after its `replaceVaultPresence(vaultID: vr.id, ...)` (line 1744) add the same with `vaultID: vr.id`.
- [ ] **Step 3:** Build — `swift build` → clean.
- [ ] **Step 4: Commit** — `fix(app): reapply pending ops after every drive presence rebuild`

---

### Task 3: Core — revert a local move (the undo primitive)

**Files:**
- Modify: `Sources/OpenPhotoCore/LibraryService+Move.swift`
- Test: `Tests/OpenPhotoCoreTests/MovePhotosTests.swift` (add)

- [ ] **Step 1: Write the failing test** (append to MovePhotosTests.swift). Reuses `makeLibrary`:

```swift
@Test func revertLocalMoveMovesFileBackAndRepathsInstance() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg"])
    _ = lib.movePhotos(try lib.items(inDir: "a"), toDir: "b")     // a/x.jpg -> b/x.jpg
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])

    try lib.revertLocalMove(from: "b/x.jpg", to: "a/x.jpg")

    #expect(try lib.items(inDir: "b").isEmpty)
    #expect(try lib.items(inDir: "a").map(\.relPath) == ["a/x.jpg"])
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/x.jpg").path))
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter revertLocalMove` → FAIL.
- [ ] **Step 3: Implement** in `LibraryService+Move.swift`:

```swift
/// Reverse a local file move (dst -> src) on the Mac primary vault: moves the file back (with its
/// sidecar + manifest patch) and re-keys the instance. No-op if there's no local instance at `dst`
/// (e.g. the photo was drive-only). Used by the reconnect review's "Undo".
public func revertLocalMove(from dstRelPath: String, to srcRelPath: String) throws {
    guard let vault = vaults.first else { return }
    let vaultID = vault.descriptor.vaultID
    guard (try? catalog.items(instanceIDs: []))  != nil else { return }   // catalog reachable
    guard catalog.instanceExists(vaultID: vaultID, relPath: dstRelPath) else { return }
    let intoDir = (srcRelPath as NSString).deletingLastPathComponent
    _ = try VaultReorganizer.moveFile(in: vault, relPath: dstRelPath, intoDirRelPath: intoDir)
    try catalog.rewriteInstancePath(vaultID: vaultID, fromRelPath: dstRelPath, toRelPath: srcRelPath)
}
```

Add a tiny catalog helper `instanceExists(vaultID:relPath:) -> Bool` in `Catalog.swift` if absent (SELECT 1 FROM instances WHERE vaultID=? AND relPath=? LIMIT 1). (Remove the placeholder `catalog reachable` guard line — replace with the real `instanceExists` check.)

- [ ] **Step 4: Run, verify pass** — `swift test --filter revertLocalMove` → PASS.
- [ ] **Step 5: Commit** — `feat(core): LibraryService.revertLocalMove (undo primitive for reconnect review)`

---

### Task 4: App — single-op propagate + undo orchestration

Refactor the per-kind apply out of `applyPendingFolderOps` so the review can act on one op; add undo that's coherent library-wide (cancels the move on every drive that queued it).

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState+FolderReorg.swift`

- [ ] **Step 1:** Extract the per-kind body of `applyPendingFolderOps` (lines 371-418, the `switch op.op` block) into:

```swift
/// Apply ONE queued op to a connected drive (the drive file/folder operation). Returns true on success
/// (caller clears the op). Mirrors the kinds in `applyPendingFolderOps`.
@MainActor func propagateFolderOp(_ op: PendingFolderOp, to driveVault: Vault, basename: String) async -> Bool {
    await Task.detached(priority: .userInitiated) { () -> Bool in
        do {
            switch op.op {
            case "move":
                guard let s = op.src, let d = op.dst else { return false }
                try VaultReorganizer.moveFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                    intoParentRelPath: mapToDriveStatic(parentOf(d), basename: basename))
            case "rename":
                guard let s = op.src, let d = op.dst else { return false }
                do { try VaultReorganizer.renameFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                        toName: (d as NSString).lastPathComponent) }
                catch VaultReorganizer.ReorgError.missing {}
            case "create":
                guard let d = op.dst else { return false }
                try VaultReorganizer.createFolder(in: driveVault, relPath: mapToDriveStatic(d, basename: basename))
            case "delete":
                guard let s = op.src else { return false }
                do { try VaultReorganizer.deleteEmptyFolder(in: driveVault, relPath: mapToDriveStatic(s, basename: basename)) }
                catch VaultReorganizer.ReorgError.notEmpty {}
            case "moveFile":
                guard let s = op.src, let d = op.dst else { return false }
                do { try VaultReorganizer.moveFile(in: driveVault, relPath: mapToDriveStatic(s, basename: basename),
                        toRelPath: mapToDriveStatic(d, basename: basename)) }
                catch VaultReorganizer.ReorgError.missing {}
            default: return false
            }
            return true
        } catch { return false }
    }.value
}
```

Rewrite `applyPendingFolderOps` to loop over `propagateFolderOp` (preserving its existing "clear on success" behavior), so Sync's path is unchanged.

- [ ] **Step 2:** Add the review actions:

```swift
/// Review "Propagate": apply one op to the connected drive, then clear it (+ its siblings on other
/// connected drives that queued the same move) and reapply presence so the catalog stays consistent.
@MainActor func reviewPropagate(_ op: PendingFolderOp) async {
    guard let library, let basename = driveBasename(),
          let drive = connectedDurableDrives().first(where: { $0.id == op.vaultID })?.vault else { return }
    if await propagateFolderOp(op, to: drive, basename: basename) {
        try? library.catalog.clearFolderOp(id: op.id)
        try? refreshCanonicalPresence(driveVault: drive)
    }
    try? refreshQueries()
}

/// Review "Undo": cancel the move using the drive as truth — revert the Mac (file + instance) once,
/// re-path EVERY drive's presence back, and clear the matching op on every drive. Drives are untouched.
@MainActor func reviewUndo(_ op: PendingFolderOp) async {
    guard let library, let s = op.src, let d = op.dst else { return }
    switch op.op {
    case "moveFile":
        try? library.revertLocalMove(from: d, to: s)
    case "move", "rename":
        try? library.revertLocalFolderMove(from: d, to: s)   // see note
    default: break
    }
    // Re-path presence back + clear the op on every drive that queued the same move.
    for vr in durableVaults {
        for sib in (try? library.catalog.pendingFolderOps(forVault: vr.id)) ?? []
                where sib.op == op.op && sib.src == s && sib.dst == d {
            if op.op == "moveFile" { try? library.catalog.rewriteVaultPresencePath(vaultID: vr.id, fromRelPath: d, toRelPath: s) }
            else { try? library.catalog.rewriteVaultPresencePaths(fromDir: d, toDir: s) }
            try? library.catalog.clearFolderOp(id: sib.id)
        }
    }
    try? library.catalog.applyLockedFolders(lockedFolders)
    try? refreshQueries()
}
```

Note: `revertLocalFolderMove(from:to:)` mirrors `revertLocalMove` for folders (reverse `VaultReorganizer.moveFolder`/`renameFolder` + `rewriteVaultPresencePaths` local). Add it to `LibraryService+Move.swift` with a test like Task 3. For `create`/`delete` ops, undo removes/recreates the empty local folder via `VaultReorganizer`.

- [ ] **Step 3:** Build — `swift build` → clean (and `swift test --filter movePhotos` still green).
- [ ] **Step 4: Commit** — `feat(app): single-op propagate + library-wide undo for the reconnect review`

---

### Task 5: App — gate reconnect/mount/verify (stop auto-draining)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (`reconnectDrive` ~1468, `autoScanConnectedDrives` ~1817, `verifyAllConnected` ~1735), `Sources/OpenPhotoApp/AppState+FolderReorg.swift` (`reconcileFolderOps` ~1813 — see below)

- [ ] **Step 1:** Introduce a non-draining reconcile for inspection paths. `reconcileFolderOps` currently drains via `applyPendingFolderOps`. Split:
  - Keep `reconcileFolderOps(driveVault:)` (drains) — used ONLY by Sync (`DriveJobSheet.computePlan`).
  - In `reconnectDrive` and `autoScanConnectedDrives`, REPLACE the `reconcileFolderOps`/`applyPendingFolderOps` call with **just** `driftScan(drive)` (which now reapplies presence — Task 2) and then `presentReviewIfNeeded(drive)` (Task 6).
  - In `verifyAllConnected`, REMOVE `await reconcileFolderOps(driveVault: drive)` (line 1735). Verify scans current state; pending moves aren't drift.

- [ ] **Step 2:** Build — `swift build` → clean.
- [ ] **Step 3: Commit** — `feat(app): reconnect/mount/verify no longer auto-apply offline ops`

---

### Task 6: App — review payload + auto-present state

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1:** Add value types + state:

```swift
struct ReviewPresentation: Identifiable { let id = UUID(); let drive: Vault }
@ObservationIgnored var reviewDrive: ReviewPresentation?   // set => DrivesView auto-presents the sheet

struct ReviewChanges {
    var ops: [PendingFolderOp] = []          // moveFile + folder ops
    var deletions: [PendingDeletion] = []
    var drift: DriftReport = DriftReport()
    var isEmpty: Bool { ops.isEmpty && deletions.isEmpty
        && drift.unknown.isEmpty && drift.missing.isEmpty && drift.changed.isEmpty }
}

@MainActor func reviewPayload(forDrive drive: Vault) -> ReviewChanges {
    let id = drive.descriptor.vaultID
    return ReviewChanges(
        ops: (try? library?.catalog.pendingFolderOps(forVault: id)) ?? [],
        deletions: drivePendingDeletions[id] ?? [],
        drift: driveDrift[id] ?? DriftReport())
}

@MainActor func presentReviewIfNeeded(_ drive: Vault) {
    guard adoptableDrive?.id != drive.descriptor.vaultID else { return }   // adoption flow owns it
    if !reviewPayload(forDrive: drive).isEmpty { reviewDrive = ReviewPresentation(drive: drive) }
}
```

(`reviewDrive` must be a stored property in the class body. If `@Observable` requires it observable for the sheet binding, drop `@ObservationIgnored`.)

- [ ] **Step 2:** Build — `swift build` → clean.
- [ ] **Step 3: Commit** — `feat(app): reconnect review payload + auto-present state`

---

### Task 7: UI — `ReviewChangesSheet`

**Files:**
- Create: `Sources/OpenPhotoApp/Drives/ReviewChangesSheet.swift`
- Reference (mirror structure): `DriftReviewSheet.swift`, `DeletionReviewSheet.swift`, `DeletionListView.swift`

- [ ] **Step 1:** Build the sheet. Header `Changes since last connect — <drive name>` + `Done`. On `.task`, run a fresh `state.driftScan(drive)` (off the cached state) then read `state.reviewPayload(forDrive:)`. Layout (a `List` like DriftReviewSheet):
  - **Group A "Your changes to push"** (omit when empty):
    - *Moves* (`ops` where `op == "moveFile"`): row `moved <name> · <srcDir> → <dstDir>`, trailing `[Undo] [Propagate]` calling `state.reviewUndo(op)` / `state.reviewPropagate(op)`, then reload. Section header bulk `[Propagate all] [Undo all]`.
    - *Folder changes* (`ops` other kinds): row `<verb> <path>`, same trailing actions.
    - *Deletions*: reuse `DeletionListView` rows; trailing `[Restore]` → `state.restorePending(entry)`, `[Bin on drive]` → `state.propagateDeletions(drive:selected:[hash])`. Bulk `[Bin all] [Restore all]`.
  - **Group B "Found on the drive"** (omit when empty): unknown / missing / changed — lift the section + row builders from `DriftReviewSheet` (Adopt / Restore / Acknowledge). Factor shared row views so both sheets use them (extract to e.g. `DriftSections.swift`).
  - Clean state (both groups empty): green "All caught up" like DriftReviewSheet's clean state.
  - Each action reloads the payload; the sheet stays open until `Done`.

- [ ] **Step 2:** Build — `swift build` → clean.
- [ ] **Step 3: Commit** — `feat(app): ReviewChangesSheet (moves + deletions + drift in one review)`

---

### Task 8: UI — DrivesView (fold in D)

**Files:**
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

- [ ] **Step 1:**
  - REMOVE the **Check** button (lines 232-234) and the fast-scan `DriftReviewSheet` path if now unused by anything but Verify.
  - Collapse the drift status line (291-312) + deletion line (278-287) into one: when `!state.reviewPayload(forDrive:).isEmpty` show "N change(s) since last connect · Review" → sets `reviewDrive`; else "No changes". (N = ops + deletions + drift counts.)
  - Add `.sheet(item: $state.reviewDrive) { p in ReviewChangesSheet(state: state, drive: p.drive) }` near the existing `.sheet(item: $drift)` (line 42).
  - **Sync** (230): add `.help("Copy new photos and edits from this Mac to the drive.")`.
  - **Verify Integrity** (235): unchanged target; add `.help("Re-hash every file on the drive to catch silent corruption. Slow — for periodic deep checks.")`.

- [ ] **Step 2:** Build — `swift build` → clean.
- [ ] **Step 3: Commit** — `feat(app): fold Check into the reconnect review; Sync/Verify tooltips (closes D)`

---

### Task 9: Integration — full suite, app build, final review

- [ ] **Step 1:** `swift test` → all green.
- [ ] **Step 2:** `scripts/make-app.sh` → `Built build/OpenPhoto.app`.
- [ ] **Step 3:** Dispatch a final code-reviewer over the whole change set (data-safety invariants, optimistic-presence invariant, no auto-apply on reconnect/verify, Sync unchanged).
- [ ] **Step 4:** Update `docs/superpowers/specs/2026-06-07-openphoto-design.md` sync-flows section with a dated changelog entry (reconnect now reviews, doesn't auto-apply). Commit.
- [ ] **Step 5:** Hand off for Jude's smoke test before cutting 1.1.0.

---

## Self-review

- **Spec coverage:** moves/folder/deletions/drift review (T7), propagate (T4), undo library-wide (T4), optimistic-presence invariant (T1/T2), gating (T5), auto-present (T6), fold Check + tooltips (T8), Sync unchanged (T5 keeps `reconcileFolderOps` for Sync). ✓
- **Type consistency:** `propagateFolderOp`/`reviewPropagate`/`reviewUndo`/`reviewPayload`/`reviewDrive`/`ReviewChanges`/`ReviewPresentation` used consistently across T4/T6/T7/T8.
- **Placeholders:** Task 3's `revertLocalMove` snippet flags the `instanceExists` helper to add (not a silent gap). Folder-op undo (`revertLocalFolderMove`) is defined as mirroring `revertLocalMove` with a test — implementer writes it in T4; if fiddly, ships propagate-only per the spec's open-risk note.
