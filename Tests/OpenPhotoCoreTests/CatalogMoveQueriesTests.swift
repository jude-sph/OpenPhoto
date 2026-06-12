import Testing
import Foundation
@testable import OpenPhotoCore

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private func hash64(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func itemsByInstanceIDResolvesLocalAndDriveRows() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let hLocal = hash64("a"); let hDrive = hash64("b")
    try cat.upsert(assets: [asset(hLocal), asset(hDrive)])
    try cat.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: hLocal, vaultID: "mac", relPath: "a/x.jpg",
                       dirPath: "a", size: 1, mtimeMs: 1)])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: hDrive, relPath: "b/y.jpg", dirPath: "b",
                           size: 1, driveRelPath: "V/b/y.jpg")])

    let items = try cat.items(instanceIDs: ["mac|a/x.jpg", "drive|b/y.jpg", "mac|nope.jpg"])
    #expect(Set(items.map(\.hash)) == [hLocal, hDrive])
    #expect(items.first { $0.hash == hDrive }?.driveRelPath == "V/b/y.jpg")
    #expect(items.first { $0.hash == hLocal }?.driveRelPath == nil)
    #expect(try cat.items(instanceIDs: []).isEmpty)
}

@Test func presenceRelPathLookupAndFileGrainRekey() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = hash64("c")
    try cat.upsert(assets: [asset(h)])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h, relPath: "a/x.jpg", dirPath: "a",
                           size: 1, driveRelPath: "V/a/x.jpg")])

    #expect(try cat.vaultPresenceRelPath(vaultID: "drive", hash: h) == "a/x.jpg")
    #expect(try cat.vaultPresenceRelPath(vaultID: "other", hash: h) == nil)

    try cat.rewriteVaultPresencePath(vaultID: "drive", fromRelPath: "a/x.jpg", toRelPath: "b/c/x.jpg")
    let rows = try cat.vaultPresenceRows(forVault: "drive")
    #expect(rows.count == 1)
    #expect(rows[0].relPath == "b/c/x.jpg" && rows[0].dirPath == "b/c"
            && rows[0].driveRelPath == "V/b/c/x.jpg")
    // Drive-only browse rows follow immediately — no rescan needed.
    #expect(try cat.items(inDir: "b/c").map(\.hash) == [h])
    #expect(try cat.items(inDir: "a").isEmpty)
}

@Test func moveFileOpRoundTripsThroughFolderOpQueue() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    _ = try cat.enqueueFolderOp(vaultID: "drive", op: "moveFile", src: "a/x.jpg", dst: "b/x.jpg")
    let ops = try cat.pendingFolderOps(forVault: "drive")
    #expect(ops.count == 1 && ops[0].op == "moveFile"
            && ops[0].src == "a/x.jpg" && ops[0].dst == "b/x.jpg")
    try cat.clearFolderOp(id: ops[0].id)
    #expect(try cat.pendingFolderOps(forVault: "drive").isEmpty)
}
