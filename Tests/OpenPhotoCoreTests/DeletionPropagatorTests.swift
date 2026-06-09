import Testing
import Foundation
@testable import OpenPhotoCore

private func presence(_ hash: String, _ drivePath: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: hash, relPath: drivePath, dirPath: "x", size: 1, driveRelPath: drivePath)
}

@Test func eligibleAppliesTheThreePartRule() {
    let onMac    = "sha256:" + String(format: "%064d", 1)   // deleted but a duplicate local copy remains
    let gone     = "sha256:" + String(format: "%064d", 2)   // deleted, no local copy, on drive  → ELIGIBLE
    let notDrive = "sha256:" + String(format: "%064d", 3)   // deleted, no local copy, NOT on drive
    let q: [PendingDeletionRecord] = [
        .init(hash: onMac, relPath: "a/1.jpg", deletedAtMs: 1),
        .init(hash: gone, relPath: "a/2.jpg", deletedAtMs: 2),
        .init(hash: notDrive, relPath: "a/3.jpg", deletedAtMs: 3),
    ]
    let local: Set<String> = [onMac]                              // only onMac still has a local instance
    let pres = [presence(onMac, "P/a/1.jpg"), presence(gone, "P/a/2.jpg")]

    let result = DeletionPropagator().eligible(queue: q, localHashes: local, presence: pres)

    #expect(result.map(\.hash) == [gone])
    #expect(result.first?.driveRelPath == "P/a/2.jpg")
    #expect(result.first?.deletedAtMs == 2)   // deletedAtMs comes from the queue record, not presence
}

@Test func eligibleExcludesWhenLocalCopyRemainsEvenIfNotOnDrive() {
    // A deleted-but-still-local hash that isn't on the drive must be excluded by the
    // no-local guard alone (it never reaches the presence lookup).
    let localNotDrive = "sha256:" + String(format: "%064d", 7)
    let result = DeletionPropagator().eligible(
        queue: [.init(hash: localNotDrive, relPath: "a/7.jpg", deletedAtMs: 1)],
        localHashes: [localNotDrive], presence: [])
    #expect(result.isEmpty)
}

@Test func eligibleEmptyWhenQueueEmptyOrNothingOnDrive() {
    let h = "sha256:" + String(format: "%064d", 9)
    #expect(DeletionPropagator().eligible(queue: [], localHashes: [], presence: [presence(h, "p")]).isEmpty)
    #expect(DeletionPropagator().eligible(
        queue: [.init(hash: h, relPath: "a", deletedAtMs: 1)],
        localHashes: [], presence: []).isEmpty)
}

@Test func propagateMovesDriveCopyToBinAndUpdatesEverything() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)

    // A file present on the drive, recorded in manifest + presence + queue.
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let onDrive = drive.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: onDrive.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("photo".utf8).write(to: onDrive)
    let hash = "sha256:" + String(repeating: "a", count: 64)
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath,
                                      size: 5, mtime: "2022-10-07T14:23:01.000Z")], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 5, driveRelPath: drivePath)])
    try cat.enqueuePendingDeletion(hash: hash, relPath: "rome/IMG_1.jpg", deletedAtMs: 1)

    let entries = DeletionPropagator().eligible(
        queue: try cat.pendingDeletions(), localHashes: try cat.instanceHashes(),
        presence: try cat.vaultPresenceRows(forVault: drive.descriptor.vaultID))
    let result = try DeletionPropagator().propagate(drive: drive, entries: entries,
                                                    macVaultID: "mac-1", catalog: cat)

    #expect(result == .init(propagated: 1, skipped: 0, failed: 0))
    #expect(!FileManager.default.fileExists(atPath: onDrive.path))                  // original gone
    let binned = drive.rootURL.appendingPathComponent(".openphoto/bin/").appendingPathComponent(drivePath)
    #expect(FileManager.default.fileExists(atPath: binned.path))                    // in drive bin
    let log = try BinStore(vault: drive).list()
    #expect(log.first?.origin == .propagated)                                       // origin: propagated
    #expect(try Manifest.read(from: drive.manifestURL).isEmpty)                     // manifest line removed
    #expect(try cat.vaultPresenceHashes(forVault: drive.descriptor.vaultID).isEmpty)// presence cleared
    #expect(try cat.pendingDeletions().isEmpty)                                     // queue cleared
    let synced = String(data: try Data(contentsOf: drive.syncLogURL), encoding: .utf8) ?? ""
    #expect(synced.contains("\"delete\""))                                          // sync-log event
}

@Test func propagateIsIdempotentWhenDriveCopyAlreadyGone() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    let hash = "sha256:" + String(repeating: "b", count: 64)
    // Presence/queue say it's there, but the file is already gone (e.g. binned earlier).
    let e = PendingDeletion(hash: hash, relPath: "a/x.jpg", driveRelPath: "Pictures/a/x.jpg",
                            size: 1, deletedAtMs: 1)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: hash, relPath: "a/x.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/x.jpg")])
    try cat.enqueuePendingDeletion(hash: hash, relPath: "a/x.jpg", deletedAtMs: 1)

    let result = try DeletionPropagator().propagate(drive: drive, entries: [e],
                                                    macVaultID: "mac-1", catalog: cat)

    #expect(result == .init(propagated: 0, skipped: 1, failed: 0))     // counted gone, not fatal
    #expect(try cat.pendingDeletions().isEmpty)                        // still cleared (goal state reached)
}

@Test func propagatePartialFailureKeepsFailedEntriesQueuedAndPreservesUnrelatedManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let driveID = drive.descriptor.vaultID
    try cat.registerVault(id: driveID, role: "canonical", rootPath: drive.rootURL.path)

    let fm = FileManager.default

    // Hash constants — 64-char hex strings (no "sha256:" prefix in the repeating part).
    let hashMoved    = "sha256:" + String(repeating: "a", count: 64)
    let hashGone     = "sha256:" + String(repeating: "b", count: 64)
    let hashWillFail = "sha256:" + String(repeating: "c", count: 64)
    let hashKeep     = "sha256:" + String(repeating: "d", count: 64)

    // Drive-relative paths.
    let drivePathMoved    = "Pictures/m/moved.jpg"
    let drivePathGone     = "Pictures/g/gone.jpg"
    let drivePathWillFail = "Pictures/f/fail.jpg"
    let drivePathKeep     = "Pictures/k/keep.jpg"

    // --- Set up drive files ---

    // moved: real file on drive
    let movedURL = drive.rootURL.appendingPathComponent(drivePathMoved)
    try fm.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("moved-photo".utf8).write(to: movedURL)

    // gone: NO file on disk (intentionally absent)

    // willFail: real file on drive
    let willFailURL = drive.rootURL.appendingPathComponent(drivePathWillFail)
    try fm.createDirectory(at: willFailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fail-photo".utf8).write(to: willFailURL)

    // willFail bin collision: pre-create the destination so moveToBin throws
    let binDest = drive.rootURL
        .appendingPathComponent(".openphoto/bin")
        .appendingPathComponent(drivePathWillFail)
    try fm.createDirectory(at: binDest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("collision".utf8).write(to: binDest)

    // keep: bystander — no file setup needed (not in batch)

    // --- Manifest: all four entries ---
    let mtime = "2024-01-01T00:00:00.000Z"
    try Manifest.write([
        ManifestEntry(hash: ContentHash(stringValue: hashMoved),    path: drivePathMoved,    size: 11, mtime: mtime),
        ManifestEntry(hash: ContentHash(stringValue: hashGone),     path: drivePathGone,     size: 5,  mtime: mtime),
        ManifestEntry(hash: ContentHash(stringValue: hashWillFail), path: drivePathWillFail, size: 10, mtime: mtime),
        ManifestEntry(hash: ContentHash(stringValue: hashKeep),     path: drivePathKeep,     size: 7,  mtime: mtime),
    ], to: drive.manifestURL)

    // --- Presence: all four ---
    try cat.replaceVaultPresence(vaultID: driveID, entries: [
        VaultPresenceEntry(hash: hashMoved,    relPath: "m/moved.jpg",  dirPath: "m", size: 11, driveRelPath: drivePathMoved),
        VaultPresenceEntry(hash: hashGone,     relPath: "g/gone.jpg",   dirPath: "g", size: 5,  driveRelPath: drivePathGone),
        VaultPresenceEntry(hash: hashWillFail, relPath: "f/fail.jpg",   dirPath: "f", size: 10, driveRelPath: drivePathWillFail),
        VaultPresenceEntry(hash: hashKeep,     relPath: "k/keep.jpg",   dirPath: "k", size: 7,  driveRelPath: drivePathKeep),
    ])

    // --- Queue: all four ---
    try cat.enqueuePendingDeletion(hash: hashMoved,    relPath: "m/moved.jpg",  deletedAtMs: 1)
    try cat.enqueuePendingDeletion(hash: hashGone,     relPath: "g/gone.jpg",   deletedAtMs: 2)
    try cat.enqueuePendingDeletion(hash: hashWillFail, relPath: "f/fail.jpg",   deletedAtMs: 3)
    try cat.enqueuePendingDeletion(hash: hashKeep,     relPath: "k/keep.jpg",   deletedAtMs: 4)

    // --- Build the three-entry batch (keep is intentionally excluded) ---
    let entryMoved    = PendingDeletion(hash: hashMoved,    relPath: "m/moved.jpg",  driveRelPath: drivePathMoved,    size: 11, deletedAtMs: 1)
    let entryGone     = PendingDeletion(hash: hashGone,     relPath: "g/gone.jpg",   driveRelPath: drivePathGone,     size: 5,  deletedAtMs: 2)
    let entryWillFail = PendingDeletion(hash: hashWillFail, relPath: "f/fail.jpg",   driveRelPath: drivePathWillFail, size: 10, deletedAtMs: 3)

    // --- Propagate ---
    let result = try DeletionPropagator().propagate(
        drive: drive,
        entries: [entryMoved, entryGone, entryWillFail],
        macVaultID: "mac-1",
        catalog: cat)

    // 1. Result counts
    #expect(result == DeletionPropagator.Result(propagated: 1, skipped: 1, failed: 1))

    // 2. moved: file gone from original path; binned; cleared from presence + queue + manifest
    #expect(!fm.fileExists(atPath: movedURL.path))
    let binnedMoved = drive.rootURL.appendingPathComponent(".openphoto/bin").appendingPathComponent(drivePathMoved)
    #expect(fm.fileExists(atPath: binnedMoved.path))
    let presenceAfter = try cat.vaultPresenceHashes(forVault: driveID)
    #expect(!presenceAfter.contains(hashMoved))
    let queueAfter = try cat.pendingDeletions().map(\.hash)
    #expect(!queueAfter.contains(hashMoved))
    let manifestAfter = try Manifest.read(from: drive.manifestURL).map(\.path)
    #expect(!manifestAfter.contains(drivePathMoved))

    // 3. willFail (SAFETY CONTRACT): original file still on disk; still in presence + queue + manifest
    #expect(fm.fileExists(atPath: willFailURL.path))
    #expect(presenceAfter.contains(hashWillFail))
    #expect(queueAfter.contains(hashWillFail))
    #expect(manifestAfter.contains(drivePathWillFail))

    // 4. gone: cleared from presence + queue + manifest (goal state reached even though no file)
    #expect(!presenceAfter.contains(hashGone))
    #expect(!queueAfter.contains(hashGone))
    #expect(!manifestAfter.contains(drivePathGone))

    // 5. keep (bystander): manifest line, presence, and queue entry all survive untouched
    #expect(manifestAfter.contains(drivePathKeep))
    #expect(presenceAfter.contains(hashKeep))
    #expect(queueAfter.contains(hashKeep))
}

@Test func deleteDriveOnlyMovesToDriveBinAndClearsPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    // Two files on the drive; we delete one, the other is a bystander.
    let goneHash = "sha256:" + String(repeating: "a", count: 64)
    let keepHash = "sha256:" + String(repeating: "b", count: 64)
    for (rel, h) in [("Pictures/a/x.jpg", goneHash), ("Pictures/a/y.jpg", keepHash)] {
        let u = drive.rootURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rel.utf8).write(to: u)
        _ = h
    }
    try Manifest.write([
        ManifestEntry(hash: ContentHash(stringValue: goneHash), path: "Pictures/a/x.jpg", size: 1, mtime: "2022-10-07T00:00:00.000Z"),
        ManifestEntry(hash: ContentHash(stringValue: keepHash), path: "Pictures/a/y.jpg", size: 1, mtime: "2022-10-07T00:00:00.000Z"),
    ], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: goneHash, relPath: "a/x.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/x.jpg"),
        VaultPresenceEntry(hash: keepHash, relPath: "a/y.jpg", dirPath: "a", size: 1, driveRelPath: "Pictures/a/y.jpg"),
    ])

    let n = try DeletionPropagator().deleteDriveOnly(
        drive: drive, entries: [(hash: goneHash, driveRelPath: "Pictures/a/x.jpg")],
        macVaultID: "mac-1", catalog: cat)

    #expect(n == 1)
    #expect(!FileManager.default.fileExists(atPath: drive.rootURL.appendingPathComponent("Pictures/a/x.jpg").path))
    let binned = drive.rootURL.appendingPathComponent(".openphoto/bin/Pictures/a/x.jpg")
    #expect(FileManager.default.fileExists(atPath: binned.path))
    #expect(try BinStore(vault: drive).list().first?.origin == .user)               // direct UI deletion
    #expect(try cat.vaultPresenceHashes(forVault: drive.descriptor.vaultID) == [keepHash])  // bystander kept
    let paths = try Manifest.read(from: drive.manifestURL).map(\.path)
    #expect(paths == ["Pictures/a/y.jpg"])                                          // gone path removed
    #expect(try cat.pendingDeletions().isEmpty)                                     // no queue involved
    let log = String(data: try Data(contentsOf: drive.syncLogURL), encoding: .utf8) ?? ""
    #expect(log.contains("\"delete\""))
}
