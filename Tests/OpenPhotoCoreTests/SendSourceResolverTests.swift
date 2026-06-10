import Testing
import Foundation
@testable import OpenPhotoCore

/// Build a local library with the given relative JPEG paths (under a "Pictures" vault) and scan it.
private func makeLibrary(_ t: TestDirs, _ relPaths: [String]) async throws -> LibraryService {
    let pics = try t.sub("Pictures")
    for (i, rel) in relPaths.enumerated() {
        // Distinct capture dates → distinct content hashes (avoids accidental dedup).
        try makeJPEG(at: pics.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:10:0\(i + 1) 14:23:01", lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    return lib
}

/// Seed `localRel`'s asset onto a fresh temp drive (named `driveSub`) and evict it so the asset
/// becomes drive-only. Returns (drive Vault, the drive-only TimelineItem). The drive must be
/// connected at evict time; the caller decides whether to pass it as "connected" to the resolver.
private func evictToDrive(_ t: TestDirs, _ lib: LibraryService,
                          localRel: String, driveSub: String) async throws -> (Vault, TimelineItem) {
    let pics = lib.vaults[0].rootURL
    let item = try #require(try lib.catalog.timelineItems().first {
        $0.driveRelPath == nil && $0.relPath == localRel })
    let drive = try Vault.openOrCreate(at: try t.sub(driveSub), role: .canonical)
    let dp = "Pictures/\(localRel)"                       // drive path includes the vault-root basename
    let df = drive.rootURL.appendingPathComponent(dp)
    try FileManager.default.createDirectory(at: df.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: pics.appendingPathComponent(localRel), to: df)
    try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: item.hash, relPath: localRel,
                           dirPath: (localRel as NSString).deletingLastPathComponent,
                           size: item.size, driveRelPath: dp)])
    _ = try await lib.evict([item], mode: .verified, connectedCanonical: [drive], canonicalPresence: [item.hash])
    let driveOnly = try #require(try lib.catalog.timelineItems().first {
        $0.hash == item.hash && $0.driveRelPath != nil })
    return (drive, driveOnly)
}

@Test func localOnlySelectionIsAllSendableFromLocalFiles() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await makeLibrary(t, ["rome/IMG_1.jpg"])
    let item = try #require(try lib.catalog.timelineItems().first)

    let plan = lib.resolveSendSources([item], connectedDrives: [], driveNames: [:])

    #expect(plan.unreachable.isEmpty)
    #expect(plan.sendable.count == 1)
    #expect(plan.sendable[0].originalURL == lib.absoluteURL(for: item))
}

@Test func driveOnlyItemWithConnectedDriveIsSendableFromDriveFile() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await makeLibrary(t, ["rome/IMG_1.jpg"])
    let (drive, driveOnly) = try await evictToDrive(t, lib, localRel: "rome/IMG_1.jpg", driveSub: "DriveA")

    let plan = lib.resolveSendSources([driveOnly], connectedDrives: [drive],
                                      driveNames: [drive.descriptor.vaultID: "DriveA"])

    #expect(plan.unreachable.isEmpty)
    #expect(plan.sendable.count == 1)
    #expect(plan.sendable[0].originalURL == drive.absoluteURL(forRelativePath: driveOnly.driveRelPath!))
}

@Test func driveOnlyItemWithAbsentDriveIsUnreachableAndNamed() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await makeLibrary(t, ["rome/IMG_1.jpg"])
    let (drive, driveOnly) = try await evictToDrive(t, lib, localRel: "rome/IMG_1.jpg", driveSub: "DriveA")

    // Drive NOT in connectedDrives → unreachable, but still named via driveNames.
    let plan = lib.resolveSendSources([driveOnly], connectedDrives: [],
                                      driveNames: [drive.descriptor.vaultID: "DriveA"])

    #expect(plan.sendable.isEmpty)
    #expect(plan.unreachable.count == 1)
    #expect(plan.unreachable[0].hash == driveOnly.hash)
    #expect(plan.unreachable[0].driveName == "DriveA")
    #expect(plan.unreachable[0].displayName == "IMG_1.jpg")
}

@Test func mixedSelectionAcrossTwoDrivesSplitsByConnectivity() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    // Three assets: A → DriveA (connected), B → DriveB (absent), C → stays local.
    let lib = try await makeLibrary(t, ["a/A.jpg", "b/B.jpg", "c/C.jpg"])
    let (driveA, aOnly) = try await evictToDrive(t, lib, localRel: "a/A.jpg", driveSub: "DriveA")
    let (driveB, bOnly) = try await evictToDrive(t, lib, localRel: "b/B.jpg", driveSub: "DriveB")
    let cLocal = try #require(try lib.catalog.timelineItems().first {
        $0.driveRelPath == nil && $0.relPath == "c/C.jpg" })

    let plan = lib.resolveSendSources([aOnly, bOnly, cLocal], connectedDrives: [driveA],
        driveNames: [driveA.descriptor.vaultID: "DriveA", driveB.descriptor.vaultID: "DriveB"])

    // Sendable: A (from DriveA) + C (local). Unreachable: B (named DriveB).
    #expect(Set(plan.sendable.map(\.hash)) == Set([aOnly.hash, cLocal.hash]))
    #expect(plan.unreachable.map(\.hash) == [bOnly.hash])
    #expect(plan.unreachable[0].driveName == "DriveB")
    let aSend = try #require(plan.sendable.first { $0.hash == aOnly.hash })
    #expect(aSend.originalURL == driveA.absoluteURL(forRelativePath: aOnly.driveRelPath!))
}

@Test func sendItemFieldsArePopulatedFromTimelineItem() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await makeLibrary(t, ["rome/IMG_1.jpg"])
    let item = try #require(try lib.catalog.timelineItems().first)

    let plan = lib.resolveSendSources([item], connectedDrives: [], driveNames: [:])
    let s = try #require(plan.sendable.first)

    #expect(s.hash == item.hash)
    #expect(s.displayName == "IMG_1.jpg")
    #expect(s.fingerprint.size == item.size)
    #expect(s.fingerprint.captureDateMs == item.takenAtMs)
    #expect(s.fingerprint.hash == item.hash)
}
