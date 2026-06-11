import Testing
import Foundation
@testable import OpenPhotoCore

private func photoAsset(_ hash: String) -> AssetRecord {
    AssetRecord(hash: hash, kind: "photo", takenAtMs: 1, pixelWidth: 64, pixelHeight: 64,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

@Test func schemaIsV10() { #expect(Catalog.schemaVersion == 10) }

@Test func phashStageWritesRowSurfacedWithDirPath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let img = t.root.appendingPathComponent("p.jpg"); try writeCheckerJPEG(at: img)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    try cat.replaceInstances(inVault: "v", with: [InstanceRecord(hash: h, vaultID: "v",
        relPath: "trip/p.jpg", dirPath: "trip", size: 1, mtimeMs: 1)])
    let ok = await PHashStage().run(hash: h, url: img, catalog: cat)
    #expect(ok)
    let rows = try cat.phashRowsWithDirPath()
    #expect(rows.contains { $0.hash == h && $0.dirPath == "trip" })
}

@Test func phashSurfacesDriveOnlyAsset() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "b", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    try cat.upsertPHash(hash: h, value: 12345)
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h, relPath: "trip/x.jpg", dirPath: "trip", size: 1,
                           driveRelPath: "Drive/trip/x.jpg")])
    #expect(try cat.phashRowsWithDirPath().contains { $0.hash == h && $0.dirPath == "trip" && $0.value == 12345 })
}

@Test func pendingDerivationIncludesPhotosForPhash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "c", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    #expect(try cat.pendingDerivation(stage: "phash").contains(h))
}

@Test func embeddingsWithTakenAtJoinsAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "d", count: 64)
    let a = AssetRecord(hash: h, kind: "photo", takenAtMs: 999, pixelWidth: 64,
        pixelHeight: 64, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [a])
    try cat.upsertEmbedding(hash: h, model: "m", dim: 3, vector: [1, 0, 0])
    let rows = try cat.embeddingsWithTakenAt(model: "m")
    #expect(rows.count == 1)
    #expect(rows[0].hash == h && rows[0].takenAtMs == 999 && rows[0].vector.count == 3)
}
