import Foundation

public enum XMP {
    static let nsX = "adobe:ns:meta/"
    static let nsRDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let nsXMP = "http://ns.adobe.com/xap/1.0/"
    static let nsDC = "http://purl.org/dc/elements/1.1/"

    public static func serialize(_ d: SidecarData) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var inner = ""
        if let c = d.caption {
            inner += "      <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(c))</rdf:li></rdf:Alt></dc:description>\n"
        }
        if !d.tags.isEmpty {
            let lis = d.tags.map { "<rdf:li>\(esc($0))</rdf:li>" }.joined()
            inner += "      <dc:subject><rdf:Bag>\(lis)</rdf:Bag></dc:subject>\n"
        }
        let ratingAttr = d.rating > 0 ? " xmp:Rating=\"\(d.rating)\"" : ""
        let labelAttr = d.favorite ? " xmp:Label=\"Favorite\"" : ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="\(nsX)">
         <rdf:RDF xmlns:rdf="\(nsRDF)">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(nsXMP)" xmlns:dc="\(nsDC)"\(ratingAttr)\(labelAttr)>
        \(inner)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    public static func parse(_ data: Data) throws -> SidecarData {
        let doc = try XMLDocument(data: data)
        guard let desc = try doc.nodes(forXPath: "//*[local-name()='Description']").first
            as? XMLElement else { return .empty }
        let rating = Int(attr(desc, "Rating") ?? "0") ?? 0
        let favorite = (attr(desc, "Label") == "Favorite")
        let caption = try desc.nodes(forXPath:
            ".//*[local-name()='description']//*[local-name()='li']")
            .first?.stringValue
        let tags = try desc.nodes(forXPath:
            ".//*[local-name()='subject']//*[local-name()='li']")
            .compactMap(\.stringValue)
        return SidecarData(rating: rating, favorite: favorite, caption: caption, tags: tags)
    }

    private static func attr(_ el: XMLElement, _ localName: String) -> String? {
        el.attributes?.first { $0.localName == localName }?.stringValue
    }
}
