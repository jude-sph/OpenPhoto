import Testing
import Foundation
@testable import OpenPhotoCore

private func makeCatalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

@Test func folderCountsRespectVideoOnly() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    func rec(_ h: String, kind: String) -> AssetRecord {
        AssetRecord(hash: h, kind: kind, takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
            livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
            caption: nil, tagsJSON: "[]")
    }
    let photo = "sha256:" + String(repeating: "a", count: 64)
    let video = "sha256:" + String(repeating: "b", count: 64)
    try c.upsert(assets: [rec(photo, kind: "photo"), rec(video, kind: "video")])
    try c.replaceInstances(inVault: "vv", with: [
        InstanceRecord(hash: photo, vaultID: "vv", relPath: "f/p.jpg", dirPath: "f", size: 1, mtimeMs: 1),
        InstanceRecord(hash: video, vaultID: "vv", relPath: "f/v.mp4", dirPath: "f", size: 1, mtimeMs: 1),
    ])
    // Unfiltered = both; videos-only = just the video. The Folders grid filters the same way, so the
    // sidebar count now matches what the grid shows.
    #expect(try c.folderCounts()["f"] == 2)
    #expect(try c.folderCounts(videoOnly: true)["f"] == 1)
}

// A photo that lives in several folders (a duplicate) must reappear in EVERY one of them once
// evicted — not just one. Regression guard for the per-file vault_presence key (v20): the old
// per-(vaultID,hash) key collapsed the drive presence to a single folder, so an evicted multi-folder
// photo vanished from all-but-one folder while still showing in the timeline.
@Test func evictedMultiFolderPhotoStaysInEveryFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let h = "sha256:" + String(repeating: "c", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "mac", role: "local", rootPath: "/tmp/pics")
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    // Same photo in TWO folders, locally and on the drive (one drive row PER FILE).
    try c.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: h, vaultID: "mac", relPath: "A/p.jpg", dirPath: "A", size: 1, mtimeMs: 1),
        InstanceRecord(hash: h, vaultID: "mac", relPath: "B/p.jpg", dirPath: "B", size: 1, mtimeMs: 1),
    ])
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "A/p.jpg", dirPath: "A", size: 1, driveRelPath: "Pictures/A/p.jpg"),
        VaultPresenceEntry(hash: h, relPath: "B/p.jpg", dirPath: "B", size: 1, driveRelPath: "Pictures/B/p.jpg"),
    ])
    // Before eviction: each folder shows the LOCAL copy; the drive rows are hidden.
    #expect(try c.items(inDir: "A").map(\.driveRelPath) == [nil])
    #expect(try c.items(inDir: "B").map(\.driveRelPath) == [nil])
    // Evict: drop the local instances in both folders.
    try c.replaceInstances(inVault: "mac", with: [])
    // After eviction: the photo stays visible as DRIVE-ONLY in BOTH folders.
    let a = try c.items(inDir: "A"); let b = try c.items(inDir: "B")
    #expect(a.count == 1 && a.first?.driveRelPath != nil)
    #expect(b.count == 1 && b.first?.driveRelPath != nil)
    #expect(try c.folderCounts()["A"] == 1)
    #expect(try c.folderCounts()["B"] == 1)
}

// Regression for the "ghost in the old folder" bug: a photo present on BOTH the Mac and an
// (offline) drive, when moved to another folder, must leave NO drive-only ghost behind. The Mac
// instance re-paths immediately; the drive's presence row MUST re-path too — otherwise the still-old
// presence row resurfaces as a drive-only row in the OLD folder while the moved copy shows in the new.
@Test func movedDualPresencePhotoLeavesNoGhostInOldFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let h = "sha256:" + String(repeating: "d", count: 64)
    try c.upsert(assets: [asset(h)])
    try c.registerVault(id: "mac", role: "local", rootPath: "/tmp/pics")
    try c.registerVault(id: "drv", role: "canonical", rootPath: "/Volumes/Drive")
    // Present in folder A both locally and on the drive (the drive row is hidden behind the local one).
    try c.replaceInstances(inVault: "mac", with: [
        InstanceRecord(hash: h, vaultID: "mac", relPath: "A/p.jpg", dirPath: "A", size: 1, mtimeMs: 1),
    ])
    try c.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: h, relPath: "A/p.jpg", dirPath: "A", size: 1,
                           driveRelPath: "Pictures/A/p.jpg"),
    ])
    #expect(try c.items(inDir: "A").count == 1)

    // Mac side only (the OLD, buggy behavior): the instance moves but the drive presence does not.
    try c.rewriteInstancePath(vaultID: "mac", fromRelPath: "A/p.jpg", toRelPath: "B/p.jpg")
    // BUG repro: the stale drive presence resurfaces as a drive-only ghost in the old folder.
    #expect(try c.items(inDir: "A").count == 1)
    #expect(try c.items(inDir: "A").first?.driveRelPath != nil)

    // The fix: also re-path the drive's presence row. Now no ghost — A is empty, B shows it once.
    try c.rewriteVaultPresencePath(vaultID: "drv", fromRelPath: "A/p.jpg", toRelPath: "B/p.jpg")
    #expect(try c.items(inDir: "A").isEmpty)
    #expect(try c.items(inDir: "B").count == 1)
    #expect(try c.folderCounts()["A"] == nil)
    #expect(try c.folderCounts()["B"] == 1)
    // The drive's driveRelPath followed the move (suffix swap A → B), so the queued file move lands right.
    let drv = try c.vaultPresenceRows(forVault: "drv")
    #expect(drv.count == 1)
    #expect(drv.first?.relPath == "B/p.jpg")
    #expect(drv.first?.driveRelPath == "Pictures/B/p.jpg")
}

@Test func purgeLocalVaultRemovesItsInstancesRegistrationAndOrphanAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let hLocal = "sha256:" + String(repeating: "a", count: 64)   // only in the local vault
    let hShared = "sha256:" + String(repeating: "b", count: 64)  // also on a drive

    try c.upsert(assets: [asset(hLocal), asset(hShared)])
    try c.registerVault(id: "v-local", role: "local", rootPath: "/tmp/pics")
    try c.replaceInstances(inVault: "v-local", with: [
        InstanceRecord(hash: hLocal, vaultID: "v-local", relPath: "a.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
        InstanceRecord(hash: hShared, vaultID: "v-local", relPath: "b.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
    ])
    // hShared is also present on a drive vault, so it must survive the purge.
    try c.registerVault(id: "v-drive", role: "canonical", rootPath: "/Volumes/Canon")
    try c.replaceVaultPresence(vaultID: "v-drive", entries: [
        VaultPresenceEntry(hash: hShared, relPath: "b.jpg", dirPath: "",
                           size: 1, driveRelPath: "b.jpg")])

    try c.purgeLocalVault(id: "v-local")

    // Vault gone, its instances gone, its photos leave the timeline.
    #expect(try c.registeredVaults().contains { $0.id == "v-local" } == false)
    // hLocal is gone from timeline; hShared remains as a drive-only item.
    let timelineHashes = try Set(c.timelineItems().map(\.hash))
    #expect(!timelineHashes.contains(hLocal))
    // hLocal is fully orphaned → its asset row is GC'd; hShared survives (drive presence).
    #expect(try c.assetHashes() == [hShared])
    // The drive vault is untouched.
    #expect(try c.registeredVaults().contains { $0.id == "v-drive" })
}
