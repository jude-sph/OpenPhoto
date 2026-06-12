import Foundation

public enum XMP {
    static let nsX      = "adobe:ns:meta/"
    static let nsRDF    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let nsXMP    = "http://ns.adobe.com/xap/1.0/"
    static let nsDC     = "http://purl.org/dc/elements/1.1/"
    static let nsMWGRS  = "http://www.metadataworkinggroup.com/schemas/regions/"
    static let nsStArea = "http://ns.adobe.com/xmp/sType/Area#"

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
        if !d.faces.isEmpty {
            inner += "      <mwg-rs:Regions rdf:parseType=\"Resource\">\n"
            inner += "        <mwg-rs:RegionList><rdf:Bag>\n"
            for face in d.faces {
                let area = FaceRegion.mwgArea(fromVision: face.visionRect)
                let fmt = { (v: Double) -> String in
                    String(format: "%.6f", v)
                }
                inner += "          <rdf:li rdf:parseType=\"Resource\">\n"
                inner += "            <mwg-rs:Name>\(esc(face.name))</mwg-rs:Name>\n"
                inner += "            <mwg-rs:Type>Face</mwg-rs:Type>\n"
                inner += "            <mwg-rs:Area"
                inner += " stArea:x=\"\(fmt(area.cx))\""
                inner += " stArea:y=\"\(fmt(area.cy))\""
                inner += " stArea:w=\"\(fmt(area.w))\""
                inner += " stArea:h=\"\(fmt(area.h))\""
                inner += " stArea:unit=\"normalized\"/>\n"
                inner += "          </rdf:li>\n"
            }
            inner += "        </rdf:Bag></mwg-rs:RegionList>\n"
            inner += "      </mwg-rs:Regions>\n"
        }
        let ratingAttr = d.rating > 0 ? " xmp:Rating=\"\(d.rating)\"" : ""
        let labelAttr = d.favorite ? " xmp:Label=\"Favorite\"" : ""
        let mwgNS = d.faces.isEmpty ? "" :
            "\n    xmlns:mwg-rs=\"\(nsMWGRS)\" xmlns:stArea=\"\(nsStArea)\""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="\(nsX)">
         <rdf:RDF xmlns:rdf="\(nsRDF)">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(nsXMP)" xmlns:dc="\(nsDC)"\(mwgNS)\(ratingAttr)\(labelAttr)>
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
        // xmp:Rating / xmp:Label may be an attribute (our serializer) OR a child
        // element (ImageIO's re-serialization). Accept both.
        let ratingStr = attr(desc, "Rating")
            ?? (try? desc.nodes(forXPath: "./*[local-name()='Rating']").first?.stringValue) ?? nil
        let rating = Int(ratingStr ?? "0") ?? 0
        let labelStr = attr(desc, "Label")
            ?? (try? desc.nodes(forXPath: "./*[local-name()='Label']").first?.stringValue) ?? nil
        let favorite = (labelStr == "Favorite")
        let caption = try desc.nodes(forXPath:
            ".//*[local-name()='description']//*[local-name()='li']")
            .first?.stringValue
        let tags = try desc.nodes(forXPath:
            ".//*[local-name()='subject']//*[local-name()='li']")
            .compactMap(\.stringValue)

        // Parse mwg-rs:Regions — each rdf:li inside RegionList that has Type=Face.
        var faces: [FaceRegion] = []
        let liNodes = try desc.nodes(forXPath:
            ".//*[local-name()='RegionList']//*[local-name()='li']")
        for liNode in liNodes {
            guard let li = liNode as? XMLElement else { continue }
            // Only handle Type=Face regions; skip others.
            let typeNodes = try li.nodes(forXPath: ".//*[local-name()='Type']")
            let typVal = typeNodes.first?.stringValue ?? ""
            guard typVal == "Face" else { continue }
            // Extract name.
            let nameNodes = try li.nodes(forXPath: ".//*[local-name()='Name']")
            guard let name = nameNodes.first?.stringValue, !name.isEmpty else { continue }
            // Extract Area element and its x/y/w/h attributes (any-namespace).
            let areaNodes = try li.nodes(forXPath: ".//*[local-name()='Area']")
            guard let areaEl = areaNodes.first as? XMLElement else { continue }
            guard
                let xStr = areaAttr(areaEl, "x"), let cx = Double(xStr),
                let yStr = areaAttr(areaEl, "y"), let cy = Double(yStr),
                let wStr = areaAttr(areaEl, "w"), let w  = Double(wStr),
                let hStr = areaAttr(areaEl, "h"), let h  = Double(hStr)
            else { continue }
            let mwg = FaceRegion.MWGArea(cx: cx, cy: cy, w: w, h: h)
            let visionRect = FaceRegion.visionRect(fromMWG: mwg)
            faces.append(FaceRegion(name: name, visionRect: visionRect))
        }

        return SidecarData(rating: rating, favorite: favorite, caption: caption,
                           tags: tags, faces: faces)
    }

    private static func attr(_ el: XMLElement, _ localName: String) -> String? {
        el.attributes?.first { $0.localName == localName }?.stringValue
    }

    /// Find an attribute by local name on an Area element (any namespace prefix).
    private static func areaAttr(_ el: XMLElement, _ localName: String) -> String? {
        el.attributes?.first { $0.localName == localName }?.stringValue
    }
}
