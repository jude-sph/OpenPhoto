import Testing
import Foundation
import GRDB
@testable import OpenPhotoCore

/// A drive vault seeded with one manifest entry + a cached thumbnail for that hash, plus a SECOND
/// cached thumbnail for a hash NOT on the drive. Returns (catalog, thumbs, drive, driveHash, otherHash).
private func snapshotFixture(_ t: TestDirs) throws
    -> (Catalog, ThumbnailStore, Vault, String, String) {
    let catalog = try Catalog(at: t.root.appendingPathComponent("cat.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let driveHash = "sha256:" + String(repeating: "a", count: 64)
    let otherHash = "sha256:" + String(repeating: "b", count: 64)
    // An asset row + manifest entry for the drive hash.
    try catalog.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: driveHash),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)
    // Two cached thumbs: one for the drive hash, one for an unrelated hash.
    for h in [driveHash, otherHash] {
        let u = thumbs.cacheURL(for: ContentHash(stringValue: h))
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: u)
    }
    return (catalog, thumbs, drive, driveHash, otherHash)
}

@Test func writeProducesSnapshotWithOnlyThisDrivesThumbs() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, otherHash) = try snapshotFixture(t)

    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let snapDir = drive.stateDirURL.appendingPathComponent("catalog-snapshot")
    let fm = FileManager.default
    let dbURL = snapDir.appendingPathComponent("catalog.sqlite")
    #expect(fm.fileExists(atPath: dbURL.path))
    var cfg = Configuration(); cfg.readonly = true
    let q = try DatabaseQueue(path: dbURL.path, configuration: cfg)
    let count = try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") }
    #expect(count == 1)
    func thumbRel(_ h: String) -> String {
        let hex = String(h.split(separator: ":").last!)
        return "thumbs/\(hex.prefix(2))/\(hex).jpg"
    }
    #expect(fm.fileExists(atPath: snapDir.appendingPathComponent(thumbRel(driveHash)).path))
    #expect(!fm.fileExists(atPath: snapDir.appendingPathComponent(thumbRel(otherHash)).path))
    let meta = try JSONSerialization.jsonObject(
        with: Data(contentsOf: snapDir.appendingPathComponent("snapshot.json"))) as! [String: Any]
    #expect(meta["source_vault_id"] as? String == drive.descriptor.vaultID)
    #expect(meta["asset_count"] as? Int == 1)
    // Re-running replaces cleanly, no leftover temp dir.
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)
    #expect(!fm.fileExists(atPath: drive.stateDirURL.appendingPathComponent("catalog-snapshot.tmp").path))
    #expect(fm.fileExists(atPath: dbURL.path))
}
