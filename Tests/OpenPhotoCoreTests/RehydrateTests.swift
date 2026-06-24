import Testing
import Foundation
@testable import OpenPhotoCore

@Test func rehydrateCopiesDriveOnlyBackToLocal() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let original = try #require(try lib.catalog.timelineItems().first)
    let originalBytes = try Data(contentsOf: pics.appendingPathComponent("rome/IMG_1.jpg"))

    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let dp = "Pictures/rome/IMG_1.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("rome/IMG_1.jpg"), to: df)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: original.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: original.size, driveRelPath: dp)])
    _ = try await lib.evict([original], mode: .verified, connectedCanonical: [drive], canonicalPresence: [original.hash])
    let driveOnly = try #require(try lib.catalog.timelineItems().first { $0.driveRelPath != nil })

    let outcome = try await lib.rehydrate([driveOnly], connectedCanonical: [drive])

    #expect(outcome == RehydrateOutcome(rehydrated: 1))
    let restored = pics.appendingPathComponent("rome/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: restored.path))
    #expect(try Data(contentsOf: restored) == originalBytes)
    #expect(try lib.catalog.timelineItems().first?.driveRelPath == nil)
}

/// Build a drive-only asset (evicted) + return (lib, drive, the drive-only item, original bytes).
private func driveOnlyFixture(_ t: TestDirs) async throws
    -> (LibraryService, Vault, TimelineItem, Data) {
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let original = try #require(try lib.catalog.timelineItems().first)
    let bytes = try Data(contentsOf: pics.appendingPathComponent("rome/IMG_1.jpg"))
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let dp = "Pictures/rome/IMG_1.jpg"
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent("rome/IMG_1.jpg"), to: df)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: original.hash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: original.size, driveRelPath: dp)])
    _ = try await lib.evict([original], mode: .verified, connectedCanonical: [drive], canonicalPresence: [original.hash])
    let driveOnly = try #require(try lib.catalog.timelineItems().first { $0.driveRelPath != nil })
    return (lib, drive, driveOnly, bytes)
}

@Test func rehydrateFailsWhenDriveNotConnected() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, _, driveOnly, _) = try await driveOnlyFixture(t)
    // Drive not in connectedCanonical → can't reach the bytes → failed, stays drive-only.
    let outcome = try await lib.rehydrate([driveOnly], connectedCanonical: [])
    #expect(outcome.rehydrated == 0)
    #expect(outcome.failed == 1)
    #expect(try lib.catalog.timelineItems().first?.driveRelPath != nil)   // still drive-only
}

@Test func rehydrateIsIdempotentWhenAlreadyLocal() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, drive, driveOnly, bytes) = try await driveOnlyFixture(t)
    _ = try await lib.rehydrate([driveOnly], connectedCanonical: [drive])   // first: restores it
    // Calling again with the (now stale) drive-only handle: the file is already local → no-op
    // success, not a failure, and the bytes are intact.
    let again = try await lib.rehydrate([driveOnly], connectedCanonical: [drive])
    #expect(again == RehydrateOutcome(rehydrated: 1))
    #expect(try Data(contentsOf: lib.vaults[0].rootURL.appendingPathComponent("rome/IMG_1.jpg")) == bytes)
}
