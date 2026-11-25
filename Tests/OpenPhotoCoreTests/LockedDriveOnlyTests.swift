import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

/// A photo evicted from a locked folder is browsed through its `vault_presence` row (no local
/// instance), so the lock must apply to it by its Mac folder path just like to a local instance.

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1000, pixelWidth: 4, pixelHeight: 4,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                caption: nil, tagsJSON: "[]")
}
private let HL = "sha256:" + String(repeating: "1", count: 64)   // evicted from locked "secret/sub"
private let HO = "sha256:" + String(repeating: "2", count: 64)   // evicted from open "secretive"
private let HM = "sha256:" + String(repeating: "3", count: 64)   // local, open "trip"

private func seeded(_ t: TestDirs) throws -> Catalog {
    let c = try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
    try c.upsert(assets: [asset(HL), asset(HO), asset(HM)])
    try c.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: HM, vaultID: "mac", relPath: "trip/m.jpg", dirPath: "trip", size: 9, mtimeMs: 0)])
    try c.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: HL, relPath: "secret/sub/l.jpg", dirPath: "secret/sub", size: 9,
                           driveRelPath: "secret/sub/l.jpg"),
        VaultPresenceEntry(hash: HO, relPath: "secretive/o.jpg", dirPath: "secretive", size: 9,
                           driveRelPath: "secretive/o.jpg"),
        VaultPresenceEntry(hash: HM, relPath: "trip/m.jpg", dirPath: "trip", size: 9,
                           driveRelPath: "trip/m.jpg"),
    ])
    try c.applyLockedFolders(["secret"])
    return c
}

@Test func evictedPhotoFromLockedFolderIsHiddenEverywhere() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try seeded(t)
    #expect(Set(try c.timelineItems().map(\.hash)) == [HO, HM])
    #expect(try c.items(inDir: "secret", recursive: true).isEmpty)
    #expect(try c.item(hash: HL) == nil)
    #expect(try c.folderCounts()["secret/sub"] == nil)
    #expect(try c.folderCounts()["secretive"] == 1)            // a name-prefix sibling is not locked
    #expect(try c.items(instanceIDs: ["drive|secret/sub/l.jpg"]).isEmpty)

    // Faces on the evicted locked photo are hidden too (same gate as a local locked photo).
    let pid = try c.createPerson(name: "P")
    _ = try c.insertFaces([FaceRow(id: nil, hash: HL, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                   embedding: [], confidence: 0.9, source: "confirmed", personID: pid)])
    #expect(try c.faceSummaries(forPerson: pid).isEmpty)

    c.revealLocked = true
    #expect(Set(try c.timelineItems().map(\.hash)) == [HL, HO, HM])
    #expect(try c.folderCounts()["secret/sub"] == 1)
    #expect(try c.faceSummaries(forPerson: pid).count == 1)

    c.revealLocked = false
    try c.applyLockedFolders([])                                // unlocking shows it again
    #expect(Set(try c.timelineItems().map(\.hash)) == [HL, HO, HM])
}

@Test func bulkStorageGathersSkipLockedContentUnlessRevealed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try seeded(t)
    try c.upsert(assets: [asset("sha256:" + String(repeating: "4", count: 64))])
    try c.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: HM, vaultID: "mac", relPath: "trip/m.jpg", dirPath: "trip", size: 9, mtimeMs: 0),
        InstanceRecord(hash: "sha256:" + String(repeating: "4", count: 64), vaultID: "mac",
                       relPath: "secret/x.jpg", dirPath: "secret", size: 9, mtimeMs: 0)])
    try c.applyLockedFolders(["secret"])
    #expect(try c.allLocalInstances().map(\.relPath) == ["trip/m.jpg"])
    #expect(Set(try c.allDriveOnlyItems().map(\.relPath)) == ["secretive/o.jpg"])
    c.revealLocked = true
    #expect(Set(try c.allLocalInstances().map(\.relPath)) == ["trip/m.jpg", "secret/x.jpg"])
    #expect(Set(try c.allDriveOnlyItems().map(\.relPath)) == ["secretive/o.jpg", "secret/sub/l.jpg"])
}

@Test func rehydratedPhotoInFullyEvictedLockedFolderStaysLocked() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try seeded(t)
    // "secret/sub" had no local instances (all evicted); a rehydrate + rescan brings one back.
    try c.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: HM, vaultID: "mac", relPath: "trip/m.jpg", dirPath: "trip", size: 9, mtimeMs: 0),
        InstanceRecord(hash: HL, vaultID: "mac", relPath: "secret/sub/l.jpg", dirPath: "secret/sub",
                       size: 9, mtimeMs: 0)])
    #expect(!(try c.timelineItems().map(\.hash)).contains(HL))
}
