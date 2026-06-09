import Testing
import Foundation
@testable import OpenPhotoCore

/// A local library with one photo, plus a temp "drive" vault that has a verified copy of it.
/// Returns (lib, localVault, driveVault, the item).
private func evictFixture(_ t: TestDirs) async throws
    -> (LibraryService, Vault, Vault, TimelineItem) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)

    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let driveFile = drive.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: driveFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let localFile = pics.appendingPathComponent("rome/IMG_1.jpg")
    try FileManager.default.copyItem(at: localFile, to: driveFile)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: item.size, driveRelPath: drivePath)])
    return (lib, lib.vaults[0], drive, item)
}

@Test func verifiedEvictReleasesLocalAndBecomesDriveOnly() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, drive, item) = try await evictFixture(t)
    let localFile = local.rootURL.appendingPathComponent("rome/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: localFile.path))

    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [drive], canonicalPresence: [item.hash])

    #expect(outcome == EvictOutcome(evicted: 1, refused: 0))
    #expect(!FileManager.default.fileExists(atPath: localFile.path))
    let items = try lib.catalog.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].driveRelPath != nil)
    #expect(items[0].hash == item.hash)
}

@Test func verifiedEvictRefusesWhenNotOnConnectedDrive() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, _, item) = try await evictFixture(t)
    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [], canonicalPresence: [])
    #expect(outcome == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}

@Test func verifiedEvictRefusesWhenDriveBytesDiffer() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, local, drive, item) = try await evictFixture(t)
    try Data("corrupted".utf8).write(to: drive.rootURL.appendingPathComponent("Pictures/rome/IMG_1.jpg"))
    let outcome = try await lib.evict([item], mode: .verified,
                                      connectedCanonical: [drive], canonicalPresence: [item.hash])
    #expect(outcome == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("rome/IMG_1.jpg").path))
}
