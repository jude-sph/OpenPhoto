import Testing
import Foundation
@testable import OpenPhotoCore

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
