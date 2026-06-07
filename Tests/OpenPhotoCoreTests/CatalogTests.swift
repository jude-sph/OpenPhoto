import Testing
import Foundation
@testable import OpenPhotoCore

private func makeAsset(_ n: Int, taken: String, kind: MediaKind = .photo) -> AssetRecord {
    AssetRecord(hash: "sha256:" + String(format: "%064d", n), kind: kind.rawValue,
                takenAtMs: Int64(ISO8601Millis.date(from: taken)!.timeIntervalSince1970 * 1000),
                pixelWidth: 100, pixelHeight: 100, latitude: nil, longitude: nil,
                cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}

@Test func upsertsAndQueriesTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("catalog.sqlite"))
    let vaultID = "v-1"
    try cat.registerVault(id: vaultID, role: "local", rootPath: "/tmp/Pictures")
    let a1 = makeAsset(1, taken: "2022-10-07T14:00:00.000Z")
    let a2 = makeAsset(2, taken: "2025-06-06T09:00:00.000Z")
    try cat.upsert(assets: [a1, a2])
    try cat.upsert(instances: [
        InstanceRecord(hash: a1.hash, vaultID: vaultID, relPath: "rome2022/IMG_1.heic",
                       dirPath: "rome2022", size: 10, mtimeMs: 0),
        InstanceRecord(hash: a2.hash, vaultID: vaultID, relPath: "lisbon25/IMG_2.heic",
                       dirPath: "lisbon25", size: 10, mtimeMs: 0),
    ])
    let items = try cat.timelineItems()
    #expect(items.count == 2)
    #expect(items.first?.hash == a2.hash)   // newest first
}

@Test func removingStaleInstancesKeepsAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    let a = makeAsset(3, taken: "2024-01-01T00:00:00.000Z")
    try cat.upsert(assets: [a])
    try cat.upsert(instances: [InstanceRecord(hash: a.hash, vaultID: "v-1",
        relPath: "x/IMG.heic", dirPath: "x", size: 1, mtimeMs: 0)])
    try cat.replaceInstances(inVault: "v-1", with: [])   // file disappeared
    #expect(try cat.timelineItems().isEmpty)             // no visible instance
    #expect(try cat.assetCount() == 1)                   // asset row kept
}

@Test func folderTreeFromInstances() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    let a = makeAsset(4, taken: "2024-01-01T00:00:00.000Z")
    let b = makeAsset(5, taken: "2024-01-02T00:00:00.000Z")
    try cat.upsert(assets: [a, b])
    try cat.upsert(instances: [
        InstanceRecord(hash: a.hash, vaultID: "v-1", relPath: "2022/rome2022/IMG_1.heic",
                       dirPath: "2022/rome2022", size: 1, mtimeMs: 0),
        InstanceRecord(hash: b.hash, vaultID: "v-1", relPath: "mac-screenshots/s.png",
                       dirPath: "mac-screenshots", size: 1, mtimeMs: 0),
    ])
    let folders = try cat.folderCounts()
    #expect(folders["2022/rome2022"] == 1)
    #expect(folders["mac-screenshots"] == 1)
}

@Test func livePairedVideoHiddenFromTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    var photo = makeAsset(6, taken: "2024-01-01T00:00:00.000Z")
    var video = makeAsset(7, taken: "2024-01-01T00:00:00.000Z", kind: .video)
    photo.livePairHash = video.hash
    video.isLivePairedVideo = true
    try cat.upsert(assets: [photo, video])
    try cat.upsert(instances: [
        InstanceRecord(hash: photo.hash, vaultID: "v-1", relPath: "a/I.heic", dirPath: "a", size: 1, mtimeMs: 0),
        InstanceRecord(hash: video.hash, vaultID: "v-1", relPath: "a/I.mov", dirPath: "a", size: 1, mtimeMs: 0),
    ])
    let items = try cat.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].livePairHash == video.hash)
}

@Test func updateHumanMetadataRoundTripsAndIgnoresUnknownHash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-1", role: "local", rootPath: "/p")
    let a = makeAsset(8, taken: "2024-03-01T00:00:00.000Z")
    try cat.upsert(assets: [a])
    try cat.upsert(instances: [InstanceRecord(hash: a.hash, vaultID: "v-1",
        relPath: "y/IMG.heic", dirPath: "y", size: 1, mtimeMs: 0)])
    try cat.updateHumanMetadata(hash: a.hash, favorite: true, rating: 4,
                                caption: "hi", tagsJSON: "[\"x\"]")
    let item = try cat.item(hash: a.hash)
    #expect(item?.favorite == true && item?.rating == 4 && item?.caption == "hi")
    // Unknown hash: silent no-op, no throw.
    try cat.updateHumanMetadata(hash: "sha256:none", favorite: false, rating: 0,
                                caption: nil, tagsJSON: "[]")
}

@Test func folderQueriesScopeByVault() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "v-pics", role: "local", rootPath: "/pics")
    try cat.registerVault(id: "v-movs", role: "local", rootPath: "/movs")
    let a = makeAsset(9, taken: "2024-01-01T00:00:00.000Z")
    let b = makeAsset(10, taken: "2024-01-02T00:00:00.000Z")
    try cat.upsert(assets: [a, b])
    try cat.upsert(instances: [
        InstanceRecord(hash: a.hash, vaultID: "v-pics", relPath: "2024/a.jpg", dirPath: "2024", size: 1, mtimeMs: 0),
        InstanceRecord(hash: b.hash, vaultID: "v-movs", relPath: "2024/b.mov", dirPath: "2024", size: 1, mtimeMs: 0),
    ])
    #expect(try cat.items(inDir: "2024").count == 2)                       // union
    #expect(try cat.items(inDir: "2024", vaultID: "v-pics").count == 1)    // scoped
    #expect(try cat.folderCounts()["2024"] == 2)
    #expect(try cat.folderCounts(vaultID: "v-movs")["2024"] == 1)
}
