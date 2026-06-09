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
