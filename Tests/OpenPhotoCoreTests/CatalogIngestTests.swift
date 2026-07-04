import Testing
import Foundation
@testable import OpenPhotoCore

private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@Test func ingestMakesAdoptedDriveFileBrowsable() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let appSupport = try t.sub("as")
    let catalog = try Catalog(at: appSupport.appendingPathComponent("catalog.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: appSupport.appendingPathComponent("thumbs"))
    let driveRoot = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: driveRoot, role: .canonical)
    let file = driveRoot.appendingPathComponent("Pictures/rome/a.jpg")
    try makeJPEG(at: file.creatingParent(), dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)

    let ingest = CatalogIngest(catalog: catalog, thumbnails: thumbs)
    try await ingest.ingestDriveFile(relPath: "Pictures/rome/a.jpg", on: drive, sourceBasenames: ["Pictures"])

    let items = try catalog.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].driveRelPath == "Pictures/rome/a.jpg" && items[0].dirPath == "rome")
    // thumbnail was cached (served without re-reading the source)
    let hash = try ContentHash.ofFile(at: file).stringValue
    #expect(await thumbs.cachedDisplayImage(for: ContentHash(stringValue: hash), maxPixel: 256) != nil)
}

// Batch ingest catalogs EVERY file (browsable) and reports progress — without rewriting the whole
// presence table per file (the "Adopt all" slowness).
@Test func ingestDriveFilesCatalogsAllAndReportsProgress() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let appSupport = try t.sub("as")
    let catalog = try Catalog(at: appSupport.appendingPathComponent("catalog.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: appSupport.appendingPathComponent("thumbs"))
    let driveRoot = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: driveRoot, role: .canonical)
    let rels = ["Pictures/a.jpg", "Pictures/rome/b.jpg", "Pictures/rome/c.jpg"]
    for (i, rel) in rels.enumerated() {
        try makeJPEG(at: driveRoot.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:01:01 00:00:0\(i)", lat: nil, lon: nil)
    }

    let ingest = CatalogIngest(catalog: catalog, thumbnails: thumbs)
    let progress = Box<[(Int, Int)]>([])
    try await ingest.ingestDriveFiles(relPaths: rels, on: drive, sourceBasenames: ["Pictures"]) { d, n in
        progress.value.append((d, n))
    }

    // All three catalogued as drive-only, browsable.
    let items = try catalog.timelineItems()
    #expect(items.count == 3)
    #expect(Set(items.compactMap(\.driveRelPath)) == Set(rels))
    // Progress reached the end with the right total.
    #expect(progress.value.last?.1 == 3)
    #expect(progress.value.map(\.0).max() == 3)
}
