# Slice 5a — Clone + First-Class Backups + Durable Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clone the canonical library to backup drives and keep those backups current (additions + deletions), treating backups as first-class durable copies with the canonical as the source of truth.

**Architecture:** Reuse the `SyncEngine` copy/verify/manifest spine via a new identity-mapped `planClone` (canonical→backup mirror) and a logging-generalized `apply`. Make deletions durable across drives by clearing a `pending_deletions` row only once **no** drive's `vault_presence` holds the hash (so unplugged backups still get the deletion on reconnect). Widen `AppState`'s drive set from canonical-only to **durable** (canonical + backup), with canonical preferred for reads.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (Command Line Tools — `swift build`/`swift test`, no Xcode), Swift Testing (`@Test`/`#expect`/`#require`), GRDB.

**Spec:** `docs/superpowers/specs/2026-06-10-phase3-slice5a-clone-backups-design.md`
**Branch:** `phase3-drives`

**Conventions (every task):**
- TDD for Core (Tasks 1–3); App (Tasks 4–5) build-verified + manual (no XCTest UI harness).
- 0 compiler warnings: `swift build 2>&1 | grep -i warning` prints nothing.
- Generated mock files only in temp dirs (`TestDirs`, `makeJPEG`, or raw `Data` bytes). **Never** `~/Pictures`/`~/Movies` or any personal folder.
- Do **not** modify `VerifiedCopy`, `Manifest`, the `SyncEngine` copy/verify spine (only add `planClone` + generalize `apply`'s logging), or the send destinations.
- No on-disk format change (`"clone"` is already a recognized §9 sync-log event; clone writes the already-specified `manifest.jsonl`/`vault.json`).
- Each task commits with the exact message shown, ending with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

**Reference shapes already in the codebase (do not redefine):**
- `SyncPlan { copies: [PlanItem]; sidecarUpdates: [PlanItem]; conflicts: [PlanItem]; totalCopyBytes: Int64 }`; `PlanItem(hash:sourceURL:destRelPath:size:)` (hash "" for sidecars).
- `Manifest.read(from: URL) -> [ManifestEntry]`, `Manifest.write(_: [ManifestEntry], to: URL)`; `ManifestEntry(hash: ContentHash, path: String, size: Int64, mtime: String)`.
- `Vault.openOrCreate(at: URL, role: VaultRole) -> Vault` (roles `.canonical` / `.backup` / `.local`); `Vault.rootURL`, `.manifestURL`, `.syncLogURL`, `.descriptor.vaultID`, `.absoluteURL(forRelativePath:)`, `.sidecarURL(forMediaAt:)`.
- `SyncEngine(library: LibraryService)`; `FileSystemVolume(rootURL: URL)` conforms to `DriveVolume`.
- `LibraryService(vaultRoots: [URL], appSupportDir: URL)`; `library.appendSyncLog(vault:event:summary:counterpartyKey:)`; `library.vaults`.
- `Catalog(at: URL)`; `registerVault(id:role:rootPath:)`, `replaceVaultPresence(vaultID:entries:)`, `enqueuePendingDeletion(hash:relPath:deletedAtMs:)`, `pendingDeletions()`, `clearPendingDeletions(hashes:)`, `removeVaultPresence(vaultID:hashes:)`, `databaseQuestionMarks(count:)`.
- `VaultPresenceEntry(hash:relPath:dirPath:size:driveRelPath:)`; `PendingDeletion(hash:relPath:driveRelPath:size:deletedAtMs:)`; `DeletionPropagator().propagate(drive:entries:macVaultID:catalog:)`.
- `ContentHash.ofFile(at:) -> ContentHash` (`.stringValue`), `ContentHash(stringValue:)`.

---

## Task 1: Clone plan (`planClone`) + generalized `apply` logging

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/SyncEngine.swift`
- Test: `Tests/OpenPhotoCoreTests/CloneTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/CloneTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// A canonical drive seeded with one file already in drive layout (`Pictures/rome/IMG_1.jpg`)
/// plus its manifest entry. Returns (lib, canonical, backup, drivePath, hash, bytes).
private func cloneFixture(_ t: TestDirs) throws
    -> (LibraryService, Vault, Vault, String, String, Data) {
    let lib = try LibraryService(vaultRoots: [try t.sub("Pictures")], appSupportDir: try t.sub("as"))
    let canonical = try Vault.openOrCreate(at: try t.sub("canon"), role: .canonical)
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let bytes = Data("photo-bytes-one".utf8)
    let f = canonical.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: f)
    let hash = try ContentHash.ofFile(at: f).stringValue
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath,
                                      size: Int64(bytes.count), mtime: "2022-10-07T14:23:01.000Z")],
                       to: canonical.manifestURL)
    return (lib, canonical, backup, drivePath, hash, bytes)
}

@Test func planCloneMirrorsIdentityMappedAndCopies() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, drivePath, _, bytes) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)

    let plan = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan.copies.count == 1)
    #expect(plan.copies[0].destRelPath == drivePath)   // identity — NOT "canon/Pictures/..."

    let result = await engine.apply(plan, destinationVault: backup,
                                    volume: FileSystemVolume(rootURL: backup.rootURL),
                                    event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    #expect(result.copied == 1)
    let copied = backup.rootURL.appendingPathComponent(drivePath)
    #expect(FileManager.default.fileExists(atPath: copied.path))
    #expect(try Data(contentsOf: copied) == bytes)
    #expect(Set(try Manifest.read(from: backup.manifestURL).map(\.path)) == [drivePath])
}

@Test func planCloneIsAdditiveDiffAndNeverOverwrites() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, drivePath, hash, _) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)
    // First clone copies the one file.
    _ = await engine.apply(try engine.planClone(source: canonical, destinationVault: backup),
                           destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    // Same hash already on backup → re-plan is empty (skip).
    #expect(try engine.planClone(source: canonical, destinationVault: backup).copies.isEmpty)

    // Add a SECOND file to canonical → only it is planned (diff-driven).
    let p2 = "Pictures/rome/IMG_2.jpg"
    let f2 = canonical.rootURL.appendingPathComponent(p2)
    try Data("photo-bytes-two".utf8).write(to: f2)
    let h2 = try ContentHash.ofFile(at: f2).stringValue
    try Manifest.write([
        ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath, size: 15, mtime: "2022-10-07T14:23:01.000Z"),
        ManifestEntry(hash: ContentHash(stringValue: h2), path: p2, size: 15, mtime: "2022-10-07T14:24:01.000Z"),
    ], to: canonical.manifestURL)
    let plan2 = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan2.copies.map(\.destRelPath) == [p2])

    // A backup file at the same path but DIFFERENT bytes → conflict, never overwritten.
    let conflicting = backup.rootURL.appendingPathComponent(p2)
    try Data("different-bytes".utf8).write(to: conflicting)
    let plan3 = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan3.copies.isEmpty)
    #expect(plan3.conflicts.map(\.destRelPath) == [p2])
    _ = await engine.apply(plan3, destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    #expect(try Data(contentsOf: conflicting) == Data("different-bytes".utf8))   // untouched
}

@Test func cloneLogsCloneEventOnDriveAndNotOnMac() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, _, _, _) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)
    _ = await engine.apply(try engine.planClone(source: canonical, destinationVault: backup),
                           destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)

    let driveLog = try String(contentsOf: backup.syncLogURL, encoding: .utf8)
    #expect(driveLog.contains("\"clone\""))
    #expect(driveLog.contains(canonical.descriptor.vaultID))
    // No mac-side "clone" line (clone is drive→drive).
    let macURL = lib.vaults[0].syncLogURL
    let macHasClone = FileManager.default.fileExists(atPath: macURL.path)
        && ((try? String(contentsOf: macURL, encoding: .utf8))?.contains("clone") ?? false)
    #expect(!macHasClone)
}
```

- [ ] **Step 2: Run the tests — verify they fail to compile**

Run: `swift test --filter CloneTests 2>&1 | tail -20`
Expected: compile failure — `planClone` and the `apply(... event: counterpartyVaultID:)` params don't exist.

- [ ] **Step 3: Add `planClone` to `SyncEngine.swift`**

Insert after the existing `plan(...)` method (before `apply`):

```swift
    /// Plan a canonical→backup mirror: diff the source drive's manifest against the destination's,
    /// queueing every source file (and sidecar) missing from the destination, IDENTITY-mapped
    /// (destRelPath == source manifest path — the source drive's paths are already in drive layout,
    /// so there is no root-basename re-prefix). Additive: a destination path with the same hash is
    /// skipped; with a different hash (or unreadable) it is a conflict, never overwritten.
    public func planClone(source: Vault, destinationVault dest: Vault) throws -> SyncPlan {
        let fm = FileManager.default
        let destEntries = try Manifest.read(from: dest.manifestURL)
        var destByPath: [String: String] = [:]
        for e in destEntries { destByPath[e.path] = e.hash.stringValue }

        var plan = SyncPlan()
        for e in try Manifest.read(from: source.manifestURL) {
            let path = e.path                                   // identity map — a mirror
            let srcURL = source.absoluteURL(forRelativePath: path)
            let destURL = dest.rootURL.appendingPathComponent(path)

            if let known = destByPath[path] {
                if known != e.hash.stringValue {
                    plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                   destRelPath: path, size: e.size))
                } // same hash → already present, skip
            } else if fm.fileExists(atPath: destURL.path) {
                let onDisk = try? ContentHash.ofFile(at: destURL).stringValue
                if onDisk != e.hash.stringValue {
                    plan.conflicts.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                                   destRelPath: path, size: e.size))
                }
            } else {
                plan.copies.append(PlanItem(hash: e.hash.stringValue, sourceURL: srcURL,
                                            destRelPath: path, size: e.size))
                plan.totalCopyBytes += e.size
            }

            // Sidecar: mirror identically (source drive's sidecar lives at <dir>/.openphoto/<file>.xmp).
            let dir = (path as NSString).deletingLastPathComponent
            let fileName = (path as NSString).lastPathComponent
            let sidecarRel = dir.isEmpty ? ".openphoto/\(fileName).xmp"
                                         : "\(dir)/.openphoto/\(fileName).xmp"
            let srcSidecar = source.rootURL.appendingPathComponent(sidecarRel)
            guard fm.fileExists(atPath: srcSidecar.path),
                  let srcData = try? Data(contentsOf: srcSidecar), !srcData.isEmpty else { continue }
            let destSidecar = dest.rootURL.appendingPathComponent(sidecarRel)
            if (try? Data(contentsOf: destSidecar)) != srcData {
                plan.sidecarUpdates.append(PlanItem(hash: "", sourceURL: srcSidecar,
                                                    destRelPath: sidecarRel, size: Int64(srcData.count)))
            }
        }
        return plan
    }
```

- [ ] **Step 4: Generalize `apply`'s signature + logging block**

Change the `apply` signature line from:

```swift
    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                      progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
```

to:

```swift
    public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                      event: String = "sync", counterpartyVaultID: String? = nil,
                      progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult {
```

Then replace the final sync-log block (the `library.appendSyncLog(vault: drive, event: "sync", ...)` + the `if let mac = library.vaults.first { ... }`) with:

```swift
        // Sync-log. Mac→drive sync logs both ends; a drive→drive op (clone) logs only the
        // destination drive with the supplied counterparty.
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
```

(Keep the `let summary = …` line exactly as-is, immediately before this block.)

- [ ] **Step 5: Run the tests — verify they pass + no warnings**

Run: `swift test --filter CloneTests 2>&1 | tail -20` → all 3 pass.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green (the existing `SyncApplyTests` still pass — they call `apply` with the trailing-closure form, which still binds to `progress`).

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/SyncEngine.swift Tests/OpenPhotoCoreTests/CloneTests.swift
git commit -m "feat(core): planClone mirrors canonical→backup identity-mapped; apply logging generalized for clone

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Durable deletion lifecycle

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Modify: `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`
- Test: `Tests/OpenPhotoCoreTests/DurableDeletionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/DurableDeletionTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

/// Seed a drive with one file at `drivePath` (manifest + presence) for `hash`.
private func seedDrive(_ drive: Vault, _ cat: Catalog, role: String, hash: String, drivePath: String) throws {
    try cat.registerVault(id: drive.descriptor.vaultID, role: role, rootPath: drive.rootURL.path)
    let f = drive.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("photo".utf8).write(to: f)
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath,
                                      size: 5, mtime: "2022-10-07T14:23:01.000Z")], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 5, driveRelPath: drivePath)])
}

private let drivePath = "Pictures/rome/IMG_1.jpg"
private let entry = PendingDeletion(hash: "sha256:" + String(repeating: "a", count: 64),
                                    relPath: "rome/IMG_1.jpg", driveRelPath: drivePath,
                                    size: 5, deletedAtMs: 1)

@Test func deletionPersistsUntilEveryDriveHasIt() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let a = try Vault.openOrCreate(at: try t.sub("A"), role: .canonical)
    let b = try Vault.openOrCreate(at: try t.sub("B"), role: .backup)
    try seedDrive(a, cat, role: "canonical", hash: entry.hash, drivePath: drivePath)
    try seedDrive(b, cat, role: "backup", hash: entry.hash, drivePath: drivePath)
    try cat.enqueuePendingDeletion(hash: entry.hash, relPath: entry.relPath, deletedAtMs: 1)

    _ = try DeletionPropagator().propagate(drive: a, entries: [entry], macVaultID: "mac", catalog: cat)
    #expect(try cat.pendingDeletions().map(\.hash) == [entry.hash])   // B still holds it → persists

    _ = try DeletionPropagator().propagate(drive: b, entries: [entry], macVaultID: "mac", catalog: cat)
    #expect(try cat.pendingDeletions().isEmpty)                       // all copies binned → cleared
}

@Test func deletionRemembersDisconnectedBackup() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let canonical = try Vault.openOrCreate(at: try t.sub("canon"), role: .canonical)
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    try seedDrive(canonical, cat, role: "canonical", hash: entry.hash, drivePath: drivePath)
    try seedDrive(backup, cat, role: "backup", hash: entry.hash, drivePath: drivePath)
    try cat.enqueuePendingDeletion(hash: entry.hash, relPath: entry.relPath, deletedAtMs: 1)

    // Backup is "unplugged": we only propagate to the canonical now.
    _ = try DeletionPropagator().propagate(drive: canonical, entries: [entry], macVaultID: "mac", catalog: cat)
    #expect(try cat.pendingDeletions().map(\.hash) == [entry.hash])   // remembered for the backup

    // Later, the backup reconnects and is reviewed/propagated → finally clears.
    _ = try DeletionPropagator().propagate(drive: backup, entries: [entry], macVaultID: "mac", catalog: cat)
    #expect(try cat.pendingDeletions().isEmpty)
}

@Test func singleDriveDeletionStillClears() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let only = try Vault.openOrCreate(at: try t.sub("only"), role: .canonical)
    try seedDrive(only, cat, role: "canonical", hash: entry.hash, drivePath: drivePath)
    try cat.enqueuePendingDeletion(hash: entry.hash, relPath: entry.relPath, deletedAtMs: 1)

    _ = try DeletionPropagator().propagate(drive: only, entries: [entry], macVaultID: "mac", catalog: cat)
    #expect(try cat.pendingDeletions().isEmpty)   // unchanged Slice 3 behavior
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter DurableDeletionTests 2>&1 | tail -20`
Expected: `deletionPersistsUntilEveryDriveHasIt` and `deletionRemembersDisconnectedBackup` FAIL (today's `propagate` clears the row after the first drive); `singleDriveDeletionStillClears` passes. (It may compile-fail first if you wrote the new method usage into a test — it doesn't here, so it's an assertion failure.)

- [ ] **Step 3: Add the catalog method**

In `Sources/OpenPhotoCore/Catalog/Catalog.swift`, immediately after `clearPendingDeletions(hashes:)`:

```swift
    /// Clear a pending deletion only once NO vault still holds the hash in presence — i.e. it has
    /// been binned on every copy. A drive that still holds it (e.g. a disconnected backup whose
    /// presence row persists) keeps the deletion pending until it too is propagated.
    public func clearPendingDeletionsWithoutPresence(hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: """
                DELETE FROM pending_deletions
                WHERE hash IN (\(marks))
                  AND NOT EXISTS (SELECT 1 FROM vault_presence vp WHERE vp.hash = pending_deletions.hash)
                """, arguments: StatementArguments(hashes))
        }
    }
```

- [ ] **Step 4: Point `propagate` at the new method**

In `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift`, in `propagate(...)`, change:

```swift
        try catalog.clearPendingDeletions(hashes: clearedHashes)
```

to:

```swift
        // Clear the queue entry only for hashes no drive holds anymore — this drive's presence was
        // just removed above, so a deletion stays pending while any OTHER drive (e.g. an unplugged
        // backup) still has it, and applies when that drive next connects.
        try catalog.clearPendingDeletionsWithoutPresence(hashes: clearedHashes)
```

Do **not** change `deleteDriveOnly`.

- [ ] **Step 5: Run — verify pass + no regressions + no warnings**

Run: `swift test --filter DurableDeletionTests 2>&1 | tail -10` → all 3 pass.
Run: `swift test --filter DeletionPropagatorTests 2>&1 | tail -10` → existing Slice 3 tests still pass (single-drive propagate clears as before, because that drive's presence is removed → no presence remains).
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Sources/OpenPhotoCore/Sync/DeletionPropagator.swift Tests/OpenPhotoCoreTests/DurableDeletionTests.swift
git commit -m "feat(core): deletions persist per-drive — clear only when no vault still holds the hash

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Behind-by-N helper + verified-evict-accepts-backup

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/BackupStatus.swift`
- Test: `Tests/OpenPhotoCoreTests/BackupStatusTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/BackupStatusTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func behindCountIsCanonicalMinusBackup() {
    #expect(backupBehindCount(canonicalHashes: ["a", "b", "c"], backupHashes: ["a"]) == 2)
    #expect(backupBehindCount(canonicalHashes: ["a"], backupHashes: ["a"]) == 0)
    #expect(backupBehindCount(canonicalHashes: [], backupHashes: ["a"]) == 0)
}

/// Verified-evict re-hashes whatever drives it's given (role-agnostic), so a BACKUP-role drive
/// holding the verified copy is sufficient to release the local original.
@Test func verifiedEvictAcceptsABackupDrive() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)

    // A BACKUP-role drive holding the same bytes, recorded in presence.
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    let dp = "Pictures/rome/IMG_1.jpg"
    let df = backup.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("rome/IMG_1.jpg"), to: df)
    try lib.catalog.registerVault(id: backup.descriptor.vaultID, role: "backup", rootPath: backup.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: backup.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: item.size, driveRelPath: dp)])

    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [backup], canonicalPresence: [item.hash])
    #expect(outcome.evicted == 1)
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter BackupStatusTests 2>&1 | tail -20`
Expected: `behindCountIsCanonicalMinusBackup` compile-fails (`backupBehindCount` undefined). `verifiedEvictAcceptsABackupDrive` is expected to PASS once it compiles (it documents existing role-agnostic behavior) — if it fails, that's a real finding to report, not a code change to make here.

- [ ] **Step 3: Add the helper**

Create `Sources/OpenPhotoCore/Sync/BackupStatus.swift`:

```swift
import Foundation

/// How many distinct assets the canonical has that a backup is missing — the backup's "behind by N".
/// Pure set difference over content hashes; the actual files to copy come from the `planClone` diff.
public func backupBehindCount(canonicalHashes: Set<String>, backupHashes: Set<String>) -> Int {
    canonicalHashes.subtracting(backupHashes).count
}
```

- [ ] **Step 4: Run — verify pass + no warnings**

Run: `swift test --filter BackupStatusTests 2>&1 | tail -10` → both pass.
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/BackupStatus.swift Tests/OpenPhotoCoreTests/BackupStatusTests.swift
git commit -m "feat(core): backupBehindCount helper; verify backups satisfy verified-evict

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Durable drives in AppState (canonical + backup)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

App glue → build-verified (no unit tests). The goal: every place that today iterates `canonicalVaults` to mean "all the durable drives" must include `backup`-role drives; the few places that mean "the authoritative canonical specifically" use a new `canonicalVault`; reads prefer canonical.

- [ ] **Step 1: Add the durable-drive properties**

Find the line that sets `canonicalVaults` (≈ line 119):

```swift
        canonicalVaults = (try? library?.catalog.registeredVaults().filter { $0.role == "canonical" }) ?? []
```

Change it to populate a durable set, and add a preferred-canonical accessor. Replace the single stored property usage by introducing:

```swift
    // All drives that hold the library durably (canonical + its backups). Used for presence,
    // browse, drift, deletion, and as candidate read/verify sources.
    private(set) var durableVaults: [VaultRecord] = []
    // The authoritative canonical (source of truth / preferred read source / migration anchor).
    var canonicalVault: VaultRecord? { durableVaults.first { $0.role == "canonical" } }
```

and set it where `canonicalVaults` was set:

```swift
        durableVaults = (try? library?.catalog.registeredVaults()
            .filter { $0.role == "canonical" || $0.role == "backup" }) ?? []
```

Remove the old `canonicalVaults` stored property **only after** Step 2 reclassifies every use.

- [ ] **Step 2: Reclassify every `canonicalVaults` use**

Run: `grep -n "canonicalVaults" Sources/OpenPhotoApp/AppState.swift`

For each hit, decide its meaning and switch it:
- **"all durable drives"** (the common case — presence refresh, drift-scan-on-connect, `connectedDriveOnly`, `rehydratableItems`/`driveOnlyDeletable`, `sendPlan`'s `connectedDrives`, the drives whose presence/drift we refresh, the durable set passed to `evict`/`rehydrate`/`deleteDriveOnly`, the deletion-review drive set) → **`durableVaults`**.
- **"the canonical specifically"** (none today strictly require this beyond labelling/preference, but the evict safety *message* and migration anchor do) → **`canonicalVault`**.

Concretely, these known sites all become `durableVaults` (verify each as you go):
- the presence refresh loop (`for vr in canonicalVaults` ≈ line 276),
- the connect/drift refresh loops (≈ 315, 393, 588, 613),
- the "other connected drives" loop in delete-flow (≈ 476: `for vr in canonicalVaults where vr.id != driveID`),
- `connectedDriveOnly(_:)` (≈ 589–593),
- `sendPlan` / `evict` / `rehydrate` drive gathering (≈ 584, 598, 668: `canonicalVaults.filter { driveIsPresent($0) }.compactMap { openVault(for: $0) }`).

- [ ] **Step 3: Canonical-preferred read source**

Where a hash can be sourced from several connected durable drives, prefer the canonical. The key site is `fullResURL(for:)` (≈ line 287) which does `canonicalVaults.first(where: { $0.id == item.vaultID })`. Because a drive-only `TimelineItem` already carries a specific `vaultID`, that lookup is exact and needs only to widen its set to `durableVaults`:

```swift
        guard let vr = durableVaults.first(where: { $0.id == item.vaultID }),
              driveIsPresent(vr), let drive = openVault(for: vr) else { return nil }
```

For the *rehydrate* and *send* source gathering, when building the connected-drive list, sort so canonical comes first, so the existing "first match wins" logic prefers it:

```swift
        let connected = durableVaults.filter { driveIsPresent($0) }
            .sorted { ($0.role == "canonical" ? 0 : 1) < ($1.role == "canonical" ? 0 : 1) }
            .compactMap { openVault(for: $0) }
```

Apply that ordering in `sendPlan` (its `connectedDrives`), `rehydrate` (its `connectedCanonical`), and `evict` (its `connectedCanonical`) so a connected canonical is the preferred verify/copy source while a backup still works as a fallback.

- [ ] **Step 4: Build clean**

Run: `swift build 2>&1 | tail -5` → clean build.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green (no behavioral change when there are no backups: `durableVaults` == the old canonical set).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "refactor(app): durable drives (canonical + backup) for presence/evict/rehydrate/send; canonical preferred for reads

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Clone & "Update backup" UI

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (orchestration glue)
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift` (role labels + actions)
- Reuse: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` (progress patterns)

App integration → build-verified + manual. Keep all copy/diff/deletion logic in Core; AppState only orchestrates (off-main for the copy, like the existing sync).

- [ ] **Step 1: AppState orchestration glue**

Add to `AppState.swift`:

```swift
    /// Hashes the canonical currently holds (from its presence mirror) — for "behind by N".
    private func canonicalHashes() -> Set<String> {
        guard let vr = canonicalVault,
              let rows = try? library?.catalog.vaultPresenceRows(forVault: vr.id) else { return [] }
        return Set(rows.map(\.hash))
    }

    /// How many photos a backup is missing relative to the canonical (catalog-only, no I/O).
    func backupBehindCount(_ vr: VaultRecord) -> Int {
        guard let rows = try? library?.catalog.vaultPresenceRows(forVault: vr.id) else { return 0 }
        return OpenPhotoCore.backupBehindCount(canonicalHashes: canonicalHashes(),
                                               backupHashes: Set(rows.map(\.hash)))
    }

    /// Clone the canonical onto `vr` (must be connected, canonical connected): copy the diff,
    /// hash-verified, then mark `vr` a backup and refresh its presence. Off-main for the copy.
    @discardableResult
    func cloneToBackup(_ vr: VaultRecord) async -> SyncResult {
        guard let lib = library,
              let canonVR = canonicalVault, driveIsPresent(canonVR),
              let canonical = openVault(for: canonVR),
              driveIsPresent(vr), let target = openVault(for: vr) else { return SyncResult() }
        let engine = SyncEngine(library: lib)
        let result = await Task.detached(priority: .userInitiated) {
            guard let plan = try? engine.planClone(source: canonical, destinationVault: target) else { return SyncResult() }
            return await engine.apply(plan, destinationVault: target,
                                      volume: FileSystemVolume(rootURL: target.rootURL),
                                      event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
        }.value
        // Flip the target to a backup and record what it now holds.
        try? lib.catalog.registerVault(id: target.descriptor.vaultID, role: "backup",
                                       rootPath: target.rootURL.path)
        try? refreshCanonicalPresence(driveVault: target)   // records the backup's presence
        reloadDrives()
        try? refreshQueries()
        return result
    }
```

(If `refreshCanonicalPresence(driveVault:)` is named differently or canonical-specific, use the same presence-recording call the existing connect/sync path uses for a drive — the point is to write `vr`'s `vault_presence` from its post-clone manifest. Writing `vault.json`'s role to `backup` happens via `Vault.openOrCreate(role:)` semantics already used for canonical; if a role *rewrite* is needed, reuse the same descriptor-write path adoption uses, or note it as a DONE_WITH_CONCERNS for the reviewer.)

- [ ] **Step 2: DrivesView — role labels + Clone/Update actions**

In `statusText(_:)`, include the role (`vr.role.capitalized` → "Canonical" / "Backup"). In the drive row's action area (next to "Sync…"/"Check"), for a connected drive that is **not** the canonical and where a canonical exists & is connected, add:

```swift
            if vr.id != state.canonicalVault?.id, state.canonicalVault.map(state.driveIsPresent) == true {
                Button(state.backupBehindCount(vr) > 0 ? "Update backup (\(state.backupBehindCount(vr)))" : "Make backup") {
                    Task { _ = await state.cloneToBackup(vr) }
                }.controlSize(.small)
            }
```

(For the first clone the drive may still be role `canonical`/unflagged; the label reads "Make backup". After cloning it becomes `backup`, and the button reads "Update backup (N)" when behind. Present a progress affordance — reuse `SyncPlanSheet`'s progress view, or a lightweight inline `ProgressView` while the `Task` runs; build-verified is enough here.)

- [ ] **Step 3: Deletion review over durable drives**

Ensure the Review-Deletions affordance (the existing `propagateDeletions` flow / its presenter) is offered for **each** connected durable drive, not just the canonical — so connecting a backup that was away during a delete surfaces its pending deletions. This follows from Task 4's `durableVaults` widening; verify the Drives panel's "Review Deletions" entry point keys off `durableVaults` and that `propagateDeletions(drive:selected:)` is invoked with the backup's `Vault`.

- [ ] **Step 4: Build clean + manual checklist**

Run: `swift build 2>&1 | tail -5` and `swift build 2>&1 | grep -i warning` → clean, no warnings.
Run: `./scripts/make-app.sh` → rebuild the bundle.

Manual (user): a second connected drive shows "Make backup"; clicking it clones (files appear, role becomes Backup); adding a photo to canonical then reconnecting shows "Update backup (1)"; deleting a photo, then connecting a backup that was unplugged, surfaces its Review-Deletions; reads prefer canonical when both connected.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Drives/DrivesView.swift
git commit -m "feat(app): Drives panel clones canonical→backup and updates backups; role labels; deletion review across durable drives

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Add a changelog entry**

After the most recent changelog bullet (the 2026-06-10 Slice 4.5 entry / the send-hardening), add:

```markdown
- **2026-06-10** — Phase 3 **Slice 5a (Clone + first-class backups + durable deletion)** implemented on `phase3-drives` (first of three Slice-5 sub-slices). **Clone** mirrors the canonical onto a backup drive (`SyncEngine.planClone`, identity-mapped — destination paths equal the canonical's drive-layout paths, no re-prefix), hash-verified and **diff-driven/re-runnable** (re-running copies only what's new); `apply`'s logging was generalized so a drive→drive clone logs a `"clone"` event on the destination only. **Backups are first-class durable drives** (`AppState.durableVaults` = canonical + backup): they contribute presence/browse/the "backed up" badge and are valid rehydrate/send/verified-evict sources, with the **canonical preferred** as the read source. **Durable deletion propagation:** a `pending_deletions` entry now clears only once **no** drive's `vault_presence` holds the hash (`Catalog.clearPendingDeletionsWithoutPresence`), so a deletion is remembered for an unplugged backup and applies (via the per-drive Review-Deletions gate) on its next connect — nothing resurrects from a backup. **No byte caching on the Mac** — the canonical is the byte store; backups pull additions from it when both are connected (the Mac remembers only per-drive presence + deletion hashes). **No on-disk format change** (`"clone"` is an existing §9 event; clone writes the already-specified `manifest.jsonl`/`vault.json`). Spec: `docs/superpowers/specs/2026-06-10-phase3-slice5a-clone-backups-design.md`. Remaining: **5b** (catalog-snapshot write + `catalog-schema.md` + fresh-Mac adoption), **5c** (migration / role flag-flip), then merge `phase3-drives` → `main`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: record Slice 5a (clone + durable backups) in master changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** §3.1 clone → Task 1; §3.2 durable drives + canonical-preferred + evict-accepts-backup → Tasks 3 (evict test) & 4; §3.3 durable deletion → Task 2; §3.4 behind-detection + update UI → Tasks 3 (helper) & 5; §6 testing → Tasks 1–3 tests; §7 decomposition → Tasks 1–6. No gaps.
- **Type consistency:** `planClone(source:destinationVault:)`, `apply(…, event:counterpartyVaultID:progress:)`, `clearPendingDeletionsWithoutPresence(hashes:)`, `backupBehindCount(canonicalHashes:backupHashes:)`, `durableVaults`/`canonicalVault`, `cloneToBackup(_:)`/`backupBehindCount(_:)` are used identically across tasks.
- **No format change** — confirmed; the `catalog-snapshot/` artifact and migration are 5b/5c.
- **Backward-compatible** — with no backups, `durableVaults` equals the old canonical set and single-drive deletion clears exactly as in Slice 3 (Task 2 regression test pins this).
