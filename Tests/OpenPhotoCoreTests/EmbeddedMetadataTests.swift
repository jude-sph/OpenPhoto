import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotoCore

@Test func xmpParseAcceptsElementFormRatingAndLabel() throws {
    // ImageIO often serializes xmp:Rating / xmp:Label as child ELEMENTS, not attributes.
    let xml = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/">
       <xmp:Rating>4</xmp:Rating>
       <xmp:Label>Favorite</xmp:Label>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">hello</rdf:li></rdf:Alt></dc:description>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """
    let d = try XMP.parse(Data(xml.utf8))
    #expect(d.rating == 4)
    #expect(d.favorite == true)
    #expect(d.caption == "hello")
}

@Test func embedThenReadRoundTripsHumanMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("p.jpg")
    try makeJPEG(at: url, dateTimeOriginal: "2021:07:04 12:00:00", lat: nil, lon: nil)

    let data = SidecarData(rating: 4, favorite: true, caption: "beach day", tags: [], faces: [])
    try EmbeddedMetadata.embed(data, exifDate: nil, latitude: nil, longitude: nil, intoImageAt: url)

    let back = try #require(EmbeddedMetadata.read(from: url))
    #expect(back.rating == 4)
    #expect(back.favorite == true)
    #expect(back.caption == "beach day")
}

@Test func embedInjectsExifDateAndGpsReadableByMetadataExtractor() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("nodate.jpg")
    try makeJPEG(at: url, dateTimeOriginal: nil, lat: nil, lon: nil)   // EXIF-less

    let when = Date(timeIntervalSince1970: 1_600_000_000)              // 2020-09-13
    try EmbeddedMetadata.embed(.empty, exifDate: when, latitude: 51.5, longitude: -0.12, intoImageAt: url)

    let m = await MetadataExtractor.extract(from: url, kind: .photo)
    #expect(abs(m.takenAt.timeIntervalSince1970 - when.timeIntervalSince1970) < 2)
    #expect(m.latitude != nil && abs((m.latitude ?? 0) - 51.5) < 0.001)
    #expect(m.longitude != nil && abs((m.longitude ?? 0) - (-0.12)) < 0.001)
}
