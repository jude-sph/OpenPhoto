import Testing
import Foundation
@testable import OpenPhotoCore

@Test func scanReadsEmbeddedCaptionAndRating() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pics")
    let img = pics.appendingPathComponent("a.jpg")
    try makeJPEG(at: img, dateTimeOriginal: "2022:05:01 09:00:00", lat: nil, lon: nil)
    try EmbeddedMetadata.embed(
        SidecarData(rating: 5, favorite: true, caption: "sunset", tags: [], faces: []),
        exifDate: nil, latitude: nil, longitude: nil, intoImageAt: img)

    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let item = try #require(try lib.catalog.timelineItems().first)
    #expect(item.caption == "sunset")
    #expect(item.rating == 5)
    #expect(item.favorite == true)
}

@Test func sidecarOverridesEmbedded() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pics")
    let img = pics.appendingPathComponent("a.jpg")
    try makeJPEG(at: img, dateTimeOriginal: "2022:05:01 09:00:00", lat: nil, lon: nil)
    try EmbeddedMetadata.embed(
        SidecarData(rating: 5, favorite: true, caption: "embedded", tags: [], faces: []),
        exifDate: nil, latitude: nil, longitude: nil, intoImageAt: img)

    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let vault = try #require(lib.vaults.first)
    try SidecarStore(vault: vault).write(
        SidecarData(rating: 2, favorite: false, caption: "edited", tags: [], faces: []),
        forMediaRelPath: "a.jpg")
    try await lib.rescan(vaultID: vault.descriptor.vaultID)

    let item = try #require(try lib.catalog.timelineItems().first)
    #expect(item.caption == "edited")
    #expect(item.rating == 2)
    #expect(item.favorite == false)
}
