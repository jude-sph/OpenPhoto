import Testing
import Foundation
@testable import OpenPhotoCore

@Test func timelineItemsVideoOnlyReturnsOnlyVideos() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let photo = "sha256:" + String(repeating: "a", count: 64)
    let video = "sha256:" + String(repeating: "b", count: 64)
    func asset(_ h: String, _ kind: String) -> AssetRecord {
        AssetRecord(hash: h, kind: kind, takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
            livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
            caption: nil, tagsJSON: "[]")
    }
    try cat.upsert(assets: [asset(photo, "photo"), asset(video, "video")])
    try cat.replaceVaultPresence(vaultID: "drv", entries: [
        VaultPresenceEntry(hash: photo, relPath: "p.jpg", dirPath: "", size: 1, driveRelPath: "p.jpg"),
        VaultPresenceEntry(hash: video, relPath: "v.mov", dirPath: "", size: 1, driveRelPath: "v.mov")])
    #expect(Set(try cat.timelineItems().map(\.hash)) == [photo, video])
    #expect(try cat.timelineItems(videoOnly: true).map(\.hash) == [video])
}
