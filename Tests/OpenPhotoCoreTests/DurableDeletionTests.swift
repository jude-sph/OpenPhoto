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
// These tests construct a `PendingDeletion` directly to exercise the per-drive *durability*
// invariant (the queue row clears only when no vault holds the hash). They deliberately bypass
// `eligible()`; the three-part eligibility rule (queued ∧ no-local-instance ∧ on-drive) that
// guards against deleting a still-locally-held photo is covered by `DeletionPropagatorTests`.
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
