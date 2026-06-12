import Testing
import Foundation
@testable import OpenPhotoCore

/// A fake FOREIGN drive in TestDirs: a real vault with seeded media, a written manifest,
/// and (optionally) a real catalog snapshot produced by the production writer.
func makeForeignDrive(_ t: TestDirs, withSnapshot: Bool) throws -> Vault {
    let root = try t.sub("their-drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    var entries: [ManifestEntry] = []
    for (rel, date) in [("rome2022/IMG_1.jpg", "2022:10:07 14:23:01"),
                        ("rome2022/IMG_2.jpg", "2022:10:07 14:23:02"),
                        ("family/IMG_3.jpg", "2022:10:07 14:23:03")] {
        let url = drive.absoluteURL(forRelativePath: rel)
        try makeJPEG(at: url.creatingParent(), dateTimeOriginal: date, lat: nil, lon: nil)
        let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: url), path: rel,
                                     size: size, mtime: "2022-10-07T14:23:01.000Z"))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    if withSnapshot {
        // Production snapshot writer over a throwaway catalog seeded with the drive's assets.
        let cat = try Catalog(at: t.root.appendingPathComponent("their-cat.sqlite"))
        let assets = entries.enumerated().map { (i, e) in
            AssetRecord(hash: e.hash.stringValue, kind: "photo",
                        takenAtMs: 1_000_000 + Int64(i), pixelWidth: nil, pixelHeight: nil,
                        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
        }
        try cat.upsert(assets: assets)
        let thumbs = ThumbnailStore(cacheDir: try t.sub("their-thumbs"))
        try CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: drive)
    }
    return drive
}

@Test func assetDatesReadsSnapshotReadOnlyAndNilsWithout() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: true)
    let dates = CatalogSnapshot.assetDates(drive: drive)
    // NOTE: Manifest.write sorts by path — re-read order ≠ seed order. Look up by path.
    let entries = try Manifest.read(from: drive.manifestURL)
    let img1 = try #require(entries.first { $0.path == "rome2022/IMG_1.jpg" })
    #expect(dates?.count == 3)
    #expect(dates?[img1.hash.stringValue] == 1_000_000)   // seeded index 0 in makeForeignDrive

    let bare = try makeForeignDriveNoSnapshot(t)
    #expect(CatalogSnapshot.assetDates(drive: bare) == nil)
}

func makeForeignDriveNoSnapshot(_ t: TestDirs) throws -> Vault {
    let root = try t.sub("bare-drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    try Manifest.write([], to: drive.manifestURL)
    return drive
}

@Test func assetHashesReturnsEveryCataloguedHash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h1 = "sha256:" + String(repeating: "a", count: 64)
    let h2 = "sha256:" + String(repeating: "b", count: 64)
    try cat.upsert(assets: [h1, h2].map {
        AssetRecord(hash: $0, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                    latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                    durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    })
    #expect(try cat.assetHashes() == [h1, h2])
}
