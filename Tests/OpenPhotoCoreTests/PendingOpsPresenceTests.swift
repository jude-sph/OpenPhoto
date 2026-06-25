import Testing
import Foundation
@testable import OpenPhotoCore

private func cat(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}
private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}

// Airtight invariant: vault_presence == manifest + pending-ops-reapplied. A manifest-driven presence
// rebuild brings a moved file back to its OLD location; reapplying the queued op must restore the
// optimistic NEW location so the photo doesn't bounce folders before the user reviews.
@Test func reapplyPendingOpsPreservesOptimisticMoveAfterPresenceRebuild() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try cat(t)
    let h = "sha256:" + String(repeating: "e", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    try c.enqueueFolderOp(vaultID: "drv", op: "moveFile", src: "A/p.jpg", dst: "B/p.jpg")
    // Simulate a manifest-driven rebuild: presence comes back at the OLD location.
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "A/p.jpg", dirPath: "A", size: 1, driveRelPath: "Pictures/A/p.jpg")])
    #expect(try c.items(inDir: "A").count == 1)         // reverted to old (the bug we must fix)

    try c.reapplyPendingOpsToPresence(vaultID: "drv")

    #expect(try c.items(inDir: "A").isEmpty)
    #expect(try c.items(inDir: "B").count == 1)
    let rows = try c.vaultPresenceRows(forVault: "drv")
    #expect(rows.first?.relPath == "B/p.jpg")
    #expect(rows.first?.driveRelPath == "Pictures/B/p.jpg")
}

@Test func reapplyFolderRenameRepathsAllFilesUnderIt() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try cat(t)
    let h = "sha256:" + String(repeating: "f", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    try c.enqueueFolderOp(vaultID: "drv", op: "rename", src: "Old", dst: "New")
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "Old/p.jpg", dirPath: "Old", size: 1, driveRelPath: "Pictures/Old/p.jpg")])

    try c.reapplyPendingOpsToPresence(vaultID: "drv")

    #expect(try c.items(inDir: "Old").isEmpty)
    #expect(try c.items(inDir: "New").count == 1)
}

// create/delete folder ops have no presence rows to move — reapply is a no-op for them.
@Test func reapplyIgnoresEmptyFolderOps() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try cat(t)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    try c.enqueueFolderOp(vaultID: "drv", op: "create", src: nil, dst: "New")
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "K/p.jpg", dirPath: "K", size: 1, driveRelPath: "Pictures/K/p.jpg")])

    try c.reapplyPendingOpsToPresence(vaultID: "drv")   // must not throw or disturb K

    #expect(try c.items(inDir: "K").count == 1)
}
