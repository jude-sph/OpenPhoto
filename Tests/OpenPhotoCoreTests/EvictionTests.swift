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

@Test func verifiedEvictLivePairIsAllOrNothing() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try await makeMOV(at: pics.appendingPathComponent("a/IMG_9.mov").creatingParent())
    let now = Date()
    for f in ["a/IMG_9.jpg", "a/IMG_9.mov"] {
        try FileManager.default.setAttributes([.modificationDate: now],
            ofItemAtPath: pics.appendingPathComponent(f).path)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    let video = try #require(item.livePairHash)

    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    var entries: [VaultPresenceEntry] = []
    for (rel, hash) in [("a/IMG_9.jpg", item.hash), ("a/IMG_9.mov", video)] {
        let dp = "Pictures/\(rel)"
        let df = drive.rootURL.appendingPathComponent(dp)
        try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pics.appendingPathComponent(rel), to: df)
        entries.append(VaultPresenceEntry(hash: hash, relPath: rel, dirPath: "a", size: 1, driveRelPath: dp))
    }
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: entries)

    let ok = try await lib.evict([item], mode: .verified,
                                 connectedCanonical: [drive], canonicalPresence: [item.hash, video])
    #expect(ok == EvictOutcome(evicted: 1, refused: 0))
    #expect(!FileManager.default.fileExists(atPath: pics.appendingPathComponent("a/IMG_9.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: pics.appendingPathComponent("a/IMG_9.mov").path))

    // A case where the video can't verify → BOTH refused, BOTH kept.
    let t2 = try TestDirs(); defer { t2.cleanup() }
    let (lib2, local2, drive2, still2) = try await evictFixtureLivePartial(t2)
    let r = try await lib2.evict([still2], mode: .verified,
                                 connectedCanonical: [drive2], canonicalPresence: [still2.hash])
    #expect(r == EvictOutcome(evicted: 0, refused: 1))
    #expect(FileManager.default.fileExists(atPath: local2.rootURL.appendingPathComponent("a/IMG_9.jpg").path))
    #expect(FileManager.default.fileExists(atPath: local2.rootURL.appendingPathComponent("a/IMG_9.mov").path))
}

/// Live pair where only the STILL is on the drive (video missing) → evict must refuse both.
private func evictFixtureLivePartial(_ t: TestDirs) async throws -> (LibraryService, Vault, Vault, TimelineItem) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try await makeMOV(at: pics.appendingPathComponent("a/IMG_9.mov").creatingParent())
    let now = Date()
    for f in ["a/IMG_9.jpg", "a/IMG_9.mov"] {
        try FileManager.default.setAttributes([.modificationDate: now],
            ofItemAtPath: pics.appendingPathComponent(f).path)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    let dp = "Pictures/a/IMG_9.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("a/IMG_9.jpg"), to: df)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: "a/IMG_9.jpg", dirPath: "a", size: 1, driveRelPath: dp)])
    return (lib, lib.vaults[0], drive, item)
}
