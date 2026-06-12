import Testing
import Foundation
@testable import OpenPhotoCore

/// Apple-Photos-style IPTC-as-XMP sidecar (generated; Apple's standard vocabulary —
/// dc:title as rdf:Alt, dc:description as rdf:Alt, dc:subject as rdf:Bag).
private func appleSidecarXML(title: String?, description: String?, keywords: [String]) -> String {
    var inner = ""
    if let title {
        inner += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>"
    }
    if let description {
        inner += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(description)</rdf:li></rdf:Alt></dc:description>"
    }
    if !keywords.isEmpty {
        let lis = keywords.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        inner += "<dc:subject><rdf:Bag>\(lis)</rdf:Bag></dc:subject>"
    }
    return """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\(inner)</rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}

@Test func parseTitleReadsDCTitleOnly() throws {
    let data = Data(appleSidecarXML(title: "Beach day", description: nil, keywords: []).utf8)
    #expect(XMP.parseTitle(data) == "Beach day")
    #expect(XMP.parseTitle(Data("<x/>".utf8)) == nil)
    // Our own sidecars (no dc:title) return nil.
    #expect(XMP.parseTitle(Data(XMP.serialize(.empty).utf8)) == nil)
}

@Test func fetchFoldsAppleSidecarWhenToggledOn() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    // Apple's ext-REPLACED naming: IMG_1.jpg → IMG_1.xmp.
    try Data(appleSidecarXML(title: "Beach day", description: "Sunset with Sam",
                             keywords: ["beach", "sam"]).utf8)
        .write(to: root.appendingPathComponent("IMG_1.xmp"))

    let src = VolumeSource(rootURL: root, displayName: "export")
    let item = try #require(try await src.enumerateItems().first)

    // Toggle OFF (default): plain copy, nothing embedded.
    let off = t.root.appendingPathComponent("off.jpg")
    try await src.fetch(item, to: off)
    #expect(EmbeddedMetadata.read(from: off) == nil
            || EmbeddedMetadata.read(from: off) == SidecarData.empty)

    // Toggle ON: description → caption, keywords → tags, folded into the copy.
    src.foldXMPSidecars = true
    let on = t.root.appendingPathComponent("on.jpg")
    try await src.fetch(item, to: on)
    let sd = try #require(EmbeddedMetadata.read(from: on))
    #expect(sd.caption == "Sunset with Sam")
    #expect(Set(sd.tags) == ["beach", "sam"])
    // The original export file is untouched (source is read-only).
    #expect(EmbeddedMetadata.read(from: root.appendingPathComponent("IMG_1.jpg")) == nil
            || EmbeddedMetadata.read(from: root.appendingPathComponent("IMG_1.jpg")) == SidecarData.empty)
}

@Test func fetchFoldUsesTitleWhenNoDescriptionAndAppendedNaming() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:02", lat: nil, lon: nil)
    // Appended naming variant: IMG_2.jpg.xmp.
    try Data(appleSidecarXML(title: "Just a title", description: nil, keywords: []).utf8)
        .write(to: root.appendingPathComponent("IMG_2.jpg.xmp"))
    let src = VolumeSource(rootURL: root, displayName: "export")
    src.foldXMPSidecars = true
    let item = try #require(try await src.enumerateItems().first)
    let out = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(item, to: out)
    #expect(EmbeddedMetadata.read(from: out)?.caption == "Just a title")
}
