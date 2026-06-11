import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

@Test func mwgRegionsRoundTrip() throws {
    // Vision-frame rect (bottom-left origin) for "Alice".
    let visionRect = CGRect(x: 0.40, y: 0.55, width: 0.18, height: 0.24)
    let region = FaceRegion(name: "Alice", visionRect: visionRect)
    let data = SidecarData(rating: 4, favorite: true, caption: "hi",
                           tags: ["rome"], faces: [region])
    let xml = XMP.serialize(data)
    let parsed = try XMP.parse(Data(xml.utf8))
    // Human metadata still round-trips alongside the regions.
    #expect(parsed.rating == 4 && parsed.favorite == true && parsed.caption == "hi")
    #expect(parsed.tags == ["rome"])
    // The region round-trips by name + rect (within float tolerance after MWG↔Vision conversion).
    let got = try #require(parsed.faces.first)
    #expect(got.name == "Alice")
    #expect(abs(got.visionRect.minX - visionRect.minX) < 0.005)
    #expect(abs(got.visionRect.minY - visionRect.minY) < 0.005)
    #expect(abs(got.visionRect.width - visionRect.width) < 0.005)
    #expect(abs(got.visionRect.height - visionRect.height) < 0.005)
}

@Test func noRegionsEmitsNoRegionBlock() throws {
    let data = SidecarData(rating: 0, favorite: false, caption: nil, tags: [], faces: [])
    let xml = XMP.serialize(data)
    #expect(!xml.contains("Regions"))
    #expect(try XMP.parse(Data(xml.utf8)).faces.isEmpty)
}

@Test func visionMWGConversionIsSymmetric() {
    // MWG Area uses CENTER + top-left origin; Vision uses lower-left CORNER. Conversion must invert.
    let v = CGRect(x: 0.3, y: 0.2, width: 0.25, height: 0.4)
    let mwg = FaceRegion.mwgArea(fromVision: v)      // (cx, cy, w, h) top-left, center-based
    let back = FaceRegion.visionRect(fromMWG: mwg)
    #expect(abs(back.minX - v.minX) < 1e-6 && abs(back.minY - v.minY) < 1e-6)
    #expect(abs(back.width - v.width) < 1e-6 && abs(back.height - v.height) < 1e-6)
}

@Test func twoRegionsRoundTripWithAllMetadata() throws {
    // Two face regions alongside all other sidecar fields.
    let r1 = FaceRegion(name: "Bob",   visionRect: CGRect(x: 0.10, y: 0.20, width: 0.15, height: 0.20))
    let r2 = FaceRegion(name: "Carol", visionRect: CGRect(x: 0.60, y: 0.30, width: 0.20, height: 0.25))
    let data = SidecarData(rating: 3, favorite: false, caption: "test & <escape>",
                           tags: ["a", "b"], faces: [r1, r2])
    let xml = XMP.serialize(data)
    let parsed = try XMP.parse(Data(xml.utf8))
    #expect(parsed.rating == 3)
    #expect(parsed.favorite == false)
    #expect(parsed.caption == "test & <escape>")
    #expect(parsed.tags == ["a", "b"])
    #expect(parsed.faces.count == 2)
    let names = Set(parsed.faces.map(\.name))
    #expect(names == Set(["Bob", "Carol"]))
    // Names are already verified above; individual rect checks follow below.
    // Check Bob and Carol rects individually.
    let bob   = try #require(parsed.faces.first { $0.name == "Bob" })
    let carol = try #require(parsed.faces.first { $0.name == "Carol" })
    #expect(abs(bob.visionRect.minX   - r1.visionRect.minX)   < 0.005)
    #expect(abs(bob.visionRect.minY   - r1.visionRect.minY)   < 0.005)
    #expect(abs(carol.visionRect.minX - r2.visionRect.minX)   < 0.005)
    #expect(abs(carol.visionRect.minY - r2.visionRect.minY)   < 0.005)
}

@Test func sidecarStoreRoundTripWithRegions() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/family/IMG_1.jpg", Data("x".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let store = SidecarStore(vault: vault)
    let region = FaceRegion(name: "Alice", visionRect: CGRect(x: 0.2, y: 0.3, width: 0.15, height: 0.2))
    let data = SidecarData(rating: 2, favorite: false, caption: "family", tags: ["fam"], faces: [region])
    try store.write(data, forMediaRelPath: "family/IMG_1.jpg")
    let readBack = try store.read(forMediaRelPath: "family/IMG_1.jpg")
    #expect(readBack.rating == 2)
    #expect(readBack.caption == "family")
    #expect(readBack.tags == ["fam"])
    #expect(readBack.faces.count == 1)
    let got = try #require(readBack.faces.first)
    #expect(got.name == "Alice")
    #expect(abs(got.visionRect.minX - 0.2) < 0.005)
    #expect(abs(got.visionRect.minY - 0.3) < 0.005)
    #expect(abs(got.visionRect.width  - 0.15) < 0.005)
    #expect(abs(got.visionRect.height - 0.20) < 0.005)
}

@Test func existingSidecarWithNoRegionsStillReadable() throws {
    // Simulate an older sidecar (no mwg-rs:Regions block) — parse must return empty faces.
    let oldXML = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmp:Rating="3">
        <dc:subject><rdf:Bag><rdf:li>trip</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    let parsed = try XMP.parse(Data(oldXML.utf8))
    #expect(parsed.rating == 3)
    #expect(parsed.tags == ["trip"])
    #expect(parsed.faces.isEmpty)   // gracefully empty — no crash, no phantom regions
}
