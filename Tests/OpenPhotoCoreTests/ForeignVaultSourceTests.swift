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

// MARK: - Task 3: ForeignVaultSource

@Test func foreignEnumerationComesFromManifestNotDiskWalk() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: true)
    // A file on disk but NOT in the manifest must not appear (manifest is the inventory)…
    try Data("stray".utf8).write(to: drive.absoluteURL(forRelativePath: "rome2022/stray.jpg"))
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")
    let items = try await src.enumerateItems()
    #expect(items.count == 3)
    #expect(!items.contains { $0.id == "rome2022/stray.jpg" })
    // …their manifest hash rides along for pre-flagging, dates come from the snapshot.
    // (Manifest re-read is path-sorted — match the entry by path, not index.)
    let entries = try Manifest.read(from: drive.manifestURL)
    let img1Entry = try #require(entries.first { $0.path == "rome2022/IMG_1.jpg" })
    let first = items.first { $0.id == "rome2022/IMG_1.jpg" }
    #expect(first?.knownHash == img1Entry.hash.stringValue)
    #expect(first?.takenAt == Date(timeIntervalSince1970: 1_000.000))   // takenAtMs 1_000_000 (seed idx 0)
    #expect(src.sourceKey == "foreign-" + drive.descriptor.vaultID)
}

@Test func foreignFolderCountsFetchSidecarAndReadOnlyDelete() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: false)
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")

    #expect(try src.folderCounts() == ["rome2022": 2, "family": 1])

    // Their sidecar bytes are exposed for the metadata-carry toggle.
    let mediaURL = drive.absoluteURL(forRelativePath: "family/IMG_3.jpg")
    let sc = drive.sidecarURL(forMediaAt: mediaURL)
    try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let xmp = Data(XMP.serialize(SidecarData(rating: 3, favorite: true, caption: nil,
                                             tags: ["beach"], faces: [])).utf8)
    try xmp.write(to: sc)
    let items = try await src.enumerateItems()
    let item3 = try #require(items.first { $0.id == "family/IMG_3.jpg" })
    #expect(src.sidecarData(for: item3) == xmp)
    #expect(src.sidecarData(for: items.first { $0.id == "rome2022/IMG_1.jpg" }!) == nil)

    // Fetch copies the bytes out; delete refuses (their drive is read-only).
    let out = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(item3, to: out)
    #expect(FileManager.default.contentsEqual(atPath: out.path, andPath: mediaURL.path))
    let res = try await src.delete([item3])
    #expect(res.count == 1 && res[0].error != nil)
    #expect(FileManager.default.fileExists(atPath: mediaURL.path))
}

@Test func foreignDatesFallBackToManifestMtimeWithoutSnapshot() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try makeForeignDrive(t, withSnapshot: false)
    let src = ForeignVaultSource(vault: drive, displayName: "Sam's drive")
    let items = try await src.enumerateItems()
    #expect(items.allSatisfy { $0.takenAt == ISO8601Millis.dateLenient(from: "2022-10-07T14:23:01.000Z") })
}
