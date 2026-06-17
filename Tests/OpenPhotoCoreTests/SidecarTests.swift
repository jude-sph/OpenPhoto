import Testing
import Foundation
@testable import OpenPhotoCore

@Test func xmpRoundTrip() throws {
    let data = SidecarData(rating: 4, favorite: true,
                           caption: "Trevi at dusk — café & \"friends\" <3",
                           tags: ["travel", "rome", "night"])
    let xml = XMP.serialize(data)
    let parsed = try XMP.parse(Data(xml.utf8))
    #expect(parsed == data)
}

@Test func captionWithControlCharsStaysParseable() throws {
    // A pasted caption can carry C0 control chars (NUL, ESC, …) that XML 1.0 forbids entirely.
    // The serializer must strip them so the sidecar still parses, not produce a corrupt document.
    let data = SidecarData(rating: 0, favorite: false,
                           caption: "line1\u{0}\u{1B}\u{7}line2\ttab\nnewline",
                           tags: ["a\u{0}b"])
    let xml = XMP.serialize(data)
    #expect(!xml.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D })
    let parsed = try XMP.parse(Data(xml.utf8))   // must not throw
    #expect(parsed.caption == "line1line2\ttab\nnewline")   // illegal scalars dropped, legal kept
    #expect(parsed.tags == ["ab"])
}

@Test func emptySidecarOmitsElements() throws {
    let xml = XMP.serialize(SidecarData(rating: 0, favorite: false, caption: nil, tags: []))
    #expect(!xml.contains("dc:subject"))
    #expect(!xml.contains("dc:description"))
    let parsed = try XMP.parse(Data(xml.utf8))
    #expect(parsed.rating == 0 && parsed.tags.isEmpty)
}

@Test func ratingIsClamped() {
    #expect(SidecarData(rating: 9, favorite: false, caption: nil, tags: []).rating == 5)
    #expect(SidecarData(rating: -3, favorite: false, caption: nil, tags: []).rating == 0)
}

@Test func storeWritesIntoFolderLevelOpenphotoDir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/rome2022/IMG_1.jpg", Data("x".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let store = SidecarStore(vault: vault)
    let data = SidecarData(rating: 5, favorite: false, caption: "c", tags: ["t"])
    try store.write(data, forMediaRelPath: "rome2022/IMG_1.jpg")
    let sidecar = root.appendingPathComponent("rome2022/.openphoto/IMG_1.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    #expect(try store.read(forMediaRelPath: "rome2022/IMG_1.jpg") == data)
    // Missing sidecar reads as empty.
    #expect(try store.read(forMediaRelPath: "rome2022/other.jpg") == SidecarData.empty)
}
