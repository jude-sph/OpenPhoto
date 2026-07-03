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

// Batch instance re-path: a multi-file move applies all path changes in ONE transaction
// (atomic, not N separate commits), each row's derived dirPath updated too.
@Test func rewriteInstancePathsRepathsEveryInstanceInOneCall() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let hX = hash64("a"); let hY = hash64("b")
    try cat.upsert(assets: [asset(hX), asset(hY)])
    try cat.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: hX, vaultID: "mac", relPath: "a/x.jpg", dirPath: "a", size: 1, mtimeMs: 1),
        InstanceRecord(hash: hY, vaultID: "mac", relPath: "a/y.jpg", dirPath: "a", size: 1, mtimeMs: 1)])

    try cat.rewriteInstancePaths(vaultID: "mac", mapping: ["a/x.jpg": "c/x.jpg", "a/y.jpg": "c/y.jpg"])

    let moved = try cat.items(instanceIDs: ["mac|c/x.jpg", "mac|c/y.jpg"])
    #expect(Set(moved.map(\.relPath)) == ["c/x.jpg", "c/y.jpg"])
    #expect(moved.first { $0.relPath == "c/x.jpg" }?.dirPath == "c")   // derived dirPath followed
    #expect(try cat.items(instanceIDs: ["mac|a/x.jpg"]).isEmpty)        // old path no longer resolves
}

// Drive presence re-path, batched: every row re-keyed in ONE transaction, each driveRelPath
// suffix-swapped to follow the move (same per-row logic as the single rewriteVaultPresencePath).
@Test func rewriteVaultPresencePathsRepathsEveryRowAndSwapsDriveRelInOneCall() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let hX = hash64("a"); let hY = hash64("b")
    try cat.upsert(assets: [asset(hX), asset(hY)])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: hX, relPath: "old/x.jpg", dirPath: "old", size: 1, driveRelPath: "Lib/old/x.jpg"),
        VaultPresenceEntry(hash: hY, relPath: "old/y.jpg", dirPath: "old", size: 1, driveRelPath: "Lib/old/y.jpg")])

    try cat.rewriteVaultPresencePaths(vaultID: "drive",
        mapping: ["old/x.jpg": "new/x.jpg", "old/y.jpg": "new/y.jpg"])

    let moved = try cat.items(instanceIDs: ["drive|new/x.jpg", "drive|new/y.jpg"])
    #expect(Set(moved.map(\.relPath)) == ["new/x.jpg", "new/y.jpg"])
    #expect(moved.first { $0.relPath == "new/x.jpg" }?.driveRelPath == "Lib/new/x.jpg")  // suffix-swapped
    #expect(moved.first { $0.relPath == "new/x.jpg" }?.dirPath == "new")
    #expect(try cat.items(instanceIDs: ["drive|old/x.jpg"]).isEmpty)
}

// Offline-drive queue, batched: all queued ops inserted in ONE transaction.
@Test func enqueueFolderOpsInsertsEveryMoveInOneCall() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.enqueueFolderOps(vaultID: "drive", op: "moveFile",
        moves: [(src: "a/x.jpg", dst: "b/x.jpg"), (src: "a/y.jpg", dst: "b/y.jpg")])
    let ops = try cat.pendingFolderOps(forVault: "drive")
    #expect(ops.count == 2)
    #expect(Set(ops.compactMap(\.src)) == ["a/x.jpg", "a/y.jpg"])
    #expect(ops.allSatisfy { $0.op == "moveFile" })
}
