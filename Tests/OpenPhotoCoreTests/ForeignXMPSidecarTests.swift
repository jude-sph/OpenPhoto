import Testing
import Foundation
@testable import OpenPhotoCore

// The exact shape Apple Photos "Export Unmodified Original + IPTC as XMP" produces.
private let gpsXMP = """
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <exif:GPSLongitude>2.6259033299999999</exif:GPSLongitude>
         <exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
         <exif:GPSLatitudeRef>N</exif:GPSLatitudeRef>
         <exif:GPSLatitude>51.456211670000002</exif:GPSLatitude>
         <photoshop:DateCreated>2017-02-17T12:18:45Z</photoshop:DateCreated>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
"""

private let subjectXMP = """
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
         <dc:subject><rdf:Seq><rdf:li>Jude</rdf:li><rdf:li>Beach</rdf:li></rdf:Seq></dc:subject>
         <dc:description><rdf:Alt><rdf:li xml:lang="x-default">A caption</rdf:li></rdf:Alt></dc:description>
         <photoshop:DateCreated>2021-06-30T19:31:25+01:00</photoshop:DateCreated>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
"""

@Test func foreignXMPParsesGPSAndDate() throws {
    let d = try #require(ForeignXMPSidecar.parse(Data(gpsXMP.utf8)))
    #expect(abs((d.latitude ?? 0) - 51.456211670) < 1e-6)     // N → positive
    #expect(abs((d.longitude ?? 0) - -2.625903330) < 1e-6)    // W → negative
    let comps = Calendar(identifier: .gregorian)
    var cal = comps; cal.timeZone = TimeZone(identifier: "UTC")!
    #expect(cal.dateComponents([.year, .month, .day], from: d.takenAt!).year == 2017)
}

@Test func foreignXMPParsesSubjectsAndCaption() throws {
    let d = try #require(ForeignXMPSidecar.parse(Data(subjectXMP.utf8)))
    #expect(d.tags == ["Jude", "Beach"])
    #expect(d.caption == "A caption")
    #expect(d.takenAt != nil)
    #expect(d.latitude == nil && d.longitude == nil)
}

@Test func foreignXMPHandlesAdobeDegreesMinutesGPS() {
    // Lightroom-style "DDD,MM.mmmmX" with the hemisphere as a trailing letter.
    #expect(abs(ForeignXMPSidecar.coordinate("51,27.3726N", ref: nil, negative: "S")! - 51.45621) < 1e-4)
    #expect(ForeignXMPSidecar.coordinate("2,37.554W", ref: nil, negative: "W")! < 0)
}

@Test func iso6709LocationParses() {
    let a = MetadataExtractor.parseISO6709("+51.456212-002.625903+010.000/")!
    #expect(abs(a.lat - 51.456212) < 1e-5)
    #expect(abs(a.lon - -2.625903) < 1e-5)
    let b = MetadataExtractor.parseISO6709("-33.8688+151.2093/")!
    #expect(b.lat < 0 && b.lon > 0)
    #expect(MetadataExtractor.parseISO6709("garbage") == nil)
}

@Test func foreignXMPEmptyOrUnparseableIsNil() {
    #expect(ForeignXMPSidecar.parse(Data("not xml".utf8)) == nil)
    #expect(ForeignXMPSidecar.parse(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>".utf8)) == nil)
}

@Test func foreignXMPSidecarURLPrefersAppendedThenReplaced() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let media = t.root.appendingPathComponent("IMG_1.jpg")
    try Data([0xFF]).write(to: media)
    #expect(ForeignXMPSidecar.sidecarURL(forMediaAt: media) == nil)
    // replace-extension form: IMG_1.xmp
    let replaced = t.root.appendingPathComponent("IMG_1.xmp")
    try Data("<x/>".utf8).write(to: replaced)
    #expect(ForeignXMPSidecar.sidecarURL(forMediaAt: media) == replaced)
    // append form IMG_1.jpg.xmp wins when present
    let appended = t.root.appendingPathComponent("IMG_1.jpg.xmp")
    try Data("<x/>".utf8).write(to: appended)
    #expect(ForeignXMPSidecar.sidecarURL(forMediaAt: media) == appended)
}
