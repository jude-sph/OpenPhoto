import Testing
import Foundation
@testable import OpenPhotoCore

@Test func takeoutFoldsJSONIntoFetchedFile() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("Takeout/Google Photos/Album")
    // EXIF-less photo (so the JSON date must be applied), plus its JSON sidecar.
    let media = dir.appendingPathComponent("IMG_9.JPG")
    try makeJPEG(at: media, dateTimeOriginal: nil, lat: nil, lon: nil)
    let json = """
    { "description": "Picnic",
      "photoTakenTime": { "timestamp": "1600000000" },
      "geoData": { "latitude": 40.0, "longitude": -73.0 },
      "favorited": true }
    """
    try t.file("Takeout/Google Photos/Album/IMG_9.JPG.supplemental-metadata.json", Data(json.utf8))

    let source = TakeoutSource(rootURL: try t.sub("Takeout"), displayName: "Takeout")
    let items = try await source.enumerateItems()
    let item = try #require(items.first { $0.name == "IMG_9.JPG" })

    let out = t.root.appendingPathComponent("staged.jpg")
    try await source.fetch(item, to: out)

    let embedded = try #require(EmbeddedMetadata.read(from: out))
    #expect(embedded.caption == "Picnic")
    #expect(embedded.favorite == true)

    let m = await MetadataExtractor.extract(from: out, kind: .photo)
    #expect(abs(m.takenAt.timeIntervalSince1970 - 1_600_000_000) < 2)   // JSON date applied
    #expect(m.latitude != nil && abs((m.latitude ?? 0) - 40.0) < 0.001)

    #expect(!FileManager.default.fileExists(atPath: out.path + ".json"))
}

@Test func takeoutImportsFileEvenWhenJSONMissing() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("Takeout/Photos")
    try makeJPEG(at: dir.appendingPathComponent("solo.JPG"),
                 dateTimeOriginal: "2019:01:01 00:00:00", lat: nil, lon: nil)
    let source = TakeoutSource(rootURL: try t.sub("Takeout"), displayName: "Takeout")
    let items = try await source.enumerateItems()
    let item = try #require(items.first { $0.name == "solo.JPG" })
    let out = t.root.appendingPathComponent("solo-out.jpg")
    try await source.fetch(item, to: out)                  // must not throw — graceful fallback
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@Test func takeoutKeepsExistingExifDateOverJSON() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("Takeout/Photos")
    // Photo already has EXIF date 2018-06-15 12:00:00 local.
    let media = dir.appendingPathComponent("HASDATE.JPG")
    try makeJPEG(at: media, dateTimeOriginal: "2018:06:15 12:00:00", lat: nil, lon: nil)
    // JSON claims a very different capture time (2020-09-13).
    let json = """
    { "photoTakenTime": { "timestamp": "1600000000" } }
    """
    try t.file("Takeout/Photos/HASDATE.JPG.supplemental-metadata.json", Data(json.utf8))

    let source = TakeoutSource(rootURL: try t.sub("Takeout"), displayName: "Takeout")
    let item = try #require(try await source.enumerateItems().first { $0.name == "HASDATE.JPG" })
    let out = t.root.appendingPathComponent("hasdate-out.jpg")
    try await source.fetch(item, to: out)

    // The EXIF DateTimeOriginal must remain the original (2018), NOT the JSON's 2020 timestamp.
    let m = await MetadataExtractor.extract(from: out, kind: .photo)
    let cal = Calendar(identifier: .gregorian)
    #expect(cal.component(.year, from: m.takenAt) == 2018)
}
