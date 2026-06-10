import Testing
import Foundation
@testable import OpenPhotoCore

/// Seed a drive (role) with `relPath`'s bytes at drive path `Pictures/<relPath>` + manifest + presence.
private func seed(_ drive: Vault, _ cat: Catalog, role: String, hash: String, relPath: String, bytes: Data) throws {
    try cat.registerVault(id: drive.descriptor.vaultID, role: role, rootPath: drive.rootURL.path)
    let dp = "Pictures/\(relPath)"
    let f = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: f)
    let existing = (try? cat.vaultPresenceRows(forVault: drive.descriptor.vaultID)) ?? []
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: existing + [
        VaultPresenceEntry(hash: hash, relPath: relPath, dirPath: (relPath as NSString).deletingLastPathComponent,
                           size: Int64(bytes.count), driveRelPath: dp)])
}

@Test func driveSourcePicksFirstHolderInOrder() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try LibraryService(vaultRoots: [try t.sub("Pictures")], appSupportDir: try t.sub("as"))
    let canonical = try Vault.openOrCreate(at: try t.sub("canon"), role: .canonical)
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    let hash = "sha256:" + String(repeating: "a", count: 64)
    let bytes = Data("photo".utf8)
    try seed(canonical, lib.catalog, role: "canonical", hash: hash, relPath: "rome/IMG_1.jpg", bytes: bytes)
    try seed(backup, lib.catalog, role: "backup", hash: hash, relPath: "rome/IMG_1.jpg", bytes: bytes)

    // canonical first → picks canonical
    #expect(lib.driveSource(forHash: hash, among: [canonical, backup])?.vault.descriptor.vaultID == canonical.descriptor.vaultID)
    // only the backup connected → picks the backup (the fallback we're adding)
    #expect(lib.driveSource(forHash: hash, among: [backup])?.vault.descriptor.vaultID == backup.descriptor.vaultID)
    #expect(lib.driveSource(forHash: hash, among: [backup])?.row.driveRelPath == "Pictures/rome/IMG_1.jpg")
    // a drive that doesn't hold it → nil
    let empty = try Vault.openOrCreate(at: try t.sub("empty"), role: .backup)
    try lib.catalog.registerVault(id: empty.descriptor.vaultID, role: "backup", rootPath: empty.rootURL.path)
    #expect(lib.driveSource(forHash: hash, among: [empty]) == nil)
}

@Test func rehydrateFallsBackToBackupWhenCanonicalAbsent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    let bytes = try Data(contentsOf: pics.appendingPathComponent("rome/IMG_1.jpg"))

    // Canonical + backup both hold the photo (canonical seeded first → lower rowid → item pins to it).
    let canonical = try Vault.openOrCreate(at: try t.sub("canon"), role: .canonical)
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    try seed(canonical, lib.catalog, role: "canonical", hash: item.hash, relPath: "rome/IMG_1.jpg", bytes: bytes)
    try seed(backup, lib.catalog, role: "backup", hash: item.hash, relPath: "rome/IMG_1.jpg", bytes: bytes)
    // Evict the local original (verified against the canonical) → item becomes drive-only, pinned to canonical.
    _ = try await lib.evict([item], mode: .verified, connectedCanonical: [canonical], canonicalPresence: [item.hash])
    let driveOnly = try #require(try lib.catalog.timelineItems().first { $0.driveRelPath != nil })

    // Canonical UNPLUGGED — only the backup is connected. Rehydrate must still restore from the backup.
    let outcome = try await lib.rehydrate([driveOnly], connectedCanonical: [backup])
    #expect(outcome == RehydrateOutcome(rehydrated: 1, failed: 0))
    #expect(try Data(contentsOf: pics.appendingPathComponent("rome/IMG_1.jpg")) == bytes)
}
