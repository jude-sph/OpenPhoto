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
