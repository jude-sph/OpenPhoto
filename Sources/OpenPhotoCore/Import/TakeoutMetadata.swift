import Foundation

/// Parsed subset of a Google Takeout per-photo JSON sidecar (Google Photos export).
public struct TakeoutMetadata: Sendable, Equatable {
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var description: String?
    public var favorited: Bool

    /// Parse a Takeout JSON. Tolerant: unknown fields ignored, 0,0 geo treated as
    /// "no location" (Google's sentinel), missing favorited → false.
    public static func parse(_ data: Data) -> TakeoutMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var takenAt: Date?
        if let pt = obj["photoTakenTime"] as? [String: Any],
           let ts = pt["timestamp"] as? String, let secs = TimeInterval(ts) {
            takenAt = Date(timeIntervalSince1970: secs)
        }

        var lat: Double?, lon: Double?
        if let geo = obj["geoData"] as? [String: Any],
           let la = geo["latitude"] as? Double, let lo = geo["longitude"] as? Double,
           !(la == 0 && lo == 0) {
            lat = la; lon = lo
        }

        let desc = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fav = (obj["favorited"] as? Bool) ?? false

        return TakeoutMetadata(takenAt: takenAt, latitude: lat, longitude: lon,
                               description: desc, favorited: fav)
    }

    public init(takenAt: Date?, latitude: Double?, longitude: Double?,
                description: String?, favorited: Bool) {
        self.takenAt = takenAt; self.latitude = latitude; self.longitude = longitude
        self.description = description; self.favorited = favorited
    }
}
