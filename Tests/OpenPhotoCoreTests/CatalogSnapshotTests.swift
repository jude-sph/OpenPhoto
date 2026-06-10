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

@Test func importSeedsAFreshCatalogForDriveOnlyBrowse() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let fresh = try Catalog(at: t.root.appendingPathComponent("fresh.sqlite"))
    let freshThumbs = ThumbnailStore(cacheDir: try t.sub("fresh-thumbs"))
    let result = try CatalogSnapshot.import(from: drive, into: fresh, thumbnails: freshThumbs)

    #expect(result.assets >= 1)
    let items = try fresh.timelineItems()
    #expect(items.contains { $0.hash == driveHash && $0.driveRelPath != nil })
    #expect(FileManager.default.fileExists(
        atPath: freshThumbs.cacheURL(for: ContentHash(stringValue: driveHash)).path))
}

@Test func importNeverClobbersLocalHumanMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    try catalog.replaceVaultPresence(vaultID: "other-vault", entries: [
        VaultPresenceEntry(hash: "sha256:" + String(repeating: "c", count: 64), relPath: "x", dirPath: "x",
                           size: 1, driveRelPath: "x")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let live = try Catalog(at: t.root.appendingPathComponent("live.sqlite"))
    try live.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: true, rating: 5, caption: "mine", tagsJSON: "[]")])

    _ = try CatalogSnapshot.import(from: drive, into: live, thumbnails: ThumbnailStore(cacheDir: try t.sub("lt")))

    let fav = try live.dbQueue.read { db in
        try Bool.fetchOne(db, sql: "SELECT favorite FROM assets WHERE hash = ?", arguments: [driveHash]) }
    #expect(fav == true)
    #expect(try live.vaultPresenceRows(forVault: "other-vault").isEmpty)
}

@Test func verifyAdoptionMakesManifestWin() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let inManifest = "sha256:" + String(repeating: "a", count: 64)
    let staleInPresence = "sha256:" + String(repeating: "b", count: 64)   // not in the manifest
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: inManifest),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)

    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: staleInPresence, relPath: "old.jpg", dirPath: "", size: 1, driveRelPath: "Pictures/old.jpg")])

    try CatalogSnapshot.verifyAdoption(drive: drive, into: cat, sourceBasenames: ["Pictures"])

    let rows = try cat.vaultPresenceRows(forVault: drive.descriptor.vaultID)
    #expect(rows.map(\.hash) == [inManifest])
    #expect(rows.first?.relPath == "rome/IMG_1.jpg")
    let kind = try cat.dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT kind FROM assets WHERE hash = ?", arguments: [inManifest]) }
    #expect(kind == "photo")
}

@Test func adoptionRoundTripMatchesManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let fresh = try Catalog(at: t.root.appendingPathComponent("fresh.sqlite"))
    _ = try CatalogSnapshot.import(from: drive, into: fresh, thumbnails: ThumbnailStore(cacheDir: try t.sub("ft")))
    try CatalogSnapshot.verifyAdoption(drive: drive, into: fresh, sourceBasenames: ["Pictures"])

    let manifestHashes = Set(try Manifest.read(from: drive.manifestURL).map { $0.hash.stringValue })
    let browseHashes = Set(try fresh.timelineItems().filter { $0.driveRelPath != nil }.map(\.hash))
    #expect(browseHashes == manifestHashes)
}
