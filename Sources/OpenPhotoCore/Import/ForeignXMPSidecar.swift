import Foundation

/// Standard fields read from a FOREIGN XMP sidecar (Apple Photos "Export Unmodified Original + IPTC
/// as XMP", Lightroom, digiKam, …) — the metadata OpenPhoto can fold back into the imported file.
public struct ForeignSidecarData: Sendable, Equatable {
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var tags: [String]
    public var caption: String?
    public var rating: Int
    public init(takenAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil,
                tags: [String] = [], caption: String? = nil, rating: Int = 0) {
        self.takenAt = takenAt; self.latitude = latitude; self.longitude = longitude
        self.tags = tags; self.caption = caption; self.rating = rating
    }
    public var isEmpty: Bool {
        takenAt == nil && latitude == nil && longitude == nil && tags.isEmpty
            && caption == nil && rating == 0
    }
}

/// Reads a foreign XMP sidecar that sits next to a media file as `<name.ext>.xmp` (append) or
/// `<name>.xmp` (replace-extension — what Apple Photos / digiKam emit). Namespace-AGNOSTIC: it
/// matches elements by local name (`local-name()`), so it tolerates whatever namespace prefixes the
/// exporting tool used. Pure (no I/O for `parse`) ⇒ unit-tested against the real export format.
public enum ForeignXMPSidecar {

    /// Locate the sidecar next to `mediaURL`. Prefers `IMG.jpg.xmp`, then `IMG.xmp`. nil if neither.
    public static func sidecarURL(forMediaAt mediaURL: URL) -> URL? {
        let fm = FileManager.default
        let appended = mediaURL.appendingPathExtension("xmp")                       // IMG.jpg.xmp
        if fm.fileExists(atPath: appended.path) { return appended }
        let replaced = mediaURL.deletingPathExtension().appendingPathExtension("xmp")  // IMG.xmp
        if fm.fileExists(atPath: replaced.path) { return replaced }
        return nil
    }

    public static func parse(_ data: Data) -> ForeignSidecarData? {
        guard let doc = try? XMLDocument(data: data, options: []) else { return nil }
        func firstText(_ local: String) -> String? {
            let v = (try? doc.nodes(forXPath: "//*[local-name()='\(local)']"))?.first?.stringValue
            let t = v?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        }
        func listItems(_ container: String) -> [String] {
            ((try? doc.nodes(forXPath:
                "//*[local-name()='\(container)']//*[local-name()='li']")) ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let takenAt = firstText("DateCreated").flatMap(parseDate)
            ?? firstText("DateTimeOriginal").flatMap(parseDate)
        let latitude  = coordinate(firstText("GPSLatitude"),  ref: firstText("GPSLatitudeRef"),  negative: "S")
        let longitude = coordinate(firstText("GPSLongitude"), ref: firstText("GPSLongitudeRef"), negative: "W")
        let tags = listItems("subject")
        let caption = firstText("description")
        let rating = firstText("Rating").flatMap { Int($0) } ?? 0

        let out = ForeignSidecarData(takenAt: takenAt, latitude: latitude, longitude: longitude,
                                     tags: tags, caption: caption, rating: rating)
        return out.isEmpty ? nil : out
    }

    // MARK: - Parsing helpers

    /// ISO-8601 date/time (`2017-02-17T12:18:45Z`, `2021-06-30T19:31:25+01:00`, or date-only).
    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // Date-only fallback (YYYY-MM-DD).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// Parse an XMP GPS coordinate. Handles decimal degrees (`51.4562`, Apple/Photos) and Adobe's
    /// `DDD,MM.mmmm[NSEW]` form (`51,27.3726N`, Lightroom). The hemisphere comes from a trailing
    /// letter or the separate `…Ref` element; `negative` is the ref letter that flips the sign.
    static func coordinate(_ raw: String?, ref: String?, negative: String) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var hemisphere = ref?.uppercased()
        if let last = s.last, "NSEWnsew".contains(last) {       // trailing hemisphere letter
            hemisphere = String(last).uppercased()
            s = String(s.dropLast())
        }
        let magnitude: Double
        if s.contains(",") {                                    // degrees,decimal-minutes
            let parts = s.split(separator: ",")
            guard parts.count == 2, let deg = Double(parts[0]), let min = Double(parts[1]) else { return nil }
            magnitude = deg + min / 60.0
        } else {
            guard let dec = Double(s) else { return nil }
            magnitude = dec
        }
        return hemisphere == negative.uppercased() ? -magnitude : magnitude
    }
}
