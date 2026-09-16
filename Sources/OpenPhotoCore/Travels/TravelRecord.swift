import Foundation

/// A place a trip visited. Resolved against the bundled GeoNames city list when the user types it
/// ("map-recognised": coordinates + GeoNames id travel with the record), or free text with every
/// optional nil when nothing matched. See vault-format-v1 §16.
public struct TravelPlace: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var region: String?
    public var country: String?
    public var countryCode: String?
    public var latitude: Double?
    public var longitude: Double?
    public var geonameID: Int?

    public init(name: String, region: String? = nil, country: String? = nil, countryCode: String? = nil,
                latitude: Double? = nil, longitude: Double? = nil, geonameID: Int? = nil) {
        self.name = name; self.region = region; self.country = country; self.countryCode = countryCode
        self.latitude = latitude; self.longitude = longitude; self.geonameID = geonameID
    }

    /// True when the place carries coordinates (a GeoNames match), false for free text.
    public var isOnMap: Bool { latitude != nil && longitude != nil }

    // Like TravelRecord below: nil is written as an explicit JSON null so a free-text place carries
    // the full key set on disk (vault-format-v1 §16.2), not a short object.
    private enum K: String, CodingKey { case name, region, country, countryCode, latitude, longitude, geonameID }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name); try c.encode(region, forKey: .region)
        try c.encode(country, forKey: .country); try c.encode(countryCode, forKey: .countryCode)
        try c.encode(latitude, forKey: .latitude); try c.encode(longitude, forKey: .longitude)
        try c.encode(geonameID, forKey: .geonameID)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = try c.decode(String.self, forKey: .name)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        geonameID = try c.decodeIfPresent(Int.self, forKey: .geonameID)
    }
}

/// One trip: the user's decisions only. Everything derivable (count, date span, detected places,
/// default cover) is computed from the catalog at display time and never stored. `nil` on
/// `name`/`startDate`/`endDate`/`places`/`coverHash` means "derive it". `places == []` means
/// "no places" (distinct from nil). Sovereign JSON at `.openphoto/travels/<id>.json`.
public struct TravelRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var folders: [String]
    public var startDate: String?     // "YYYY-MM-DD"
    public var endDate: String?
    public var places: [TravelPlace]?
    public var coverHash: String?
    public var createdAtMs: Int64
    public var modifiedAtMs: Int64

    public init(id: String, name: String?, folders: [String], startDate: String?, endDate: String?,
                places: [TravelPlace]?, coverHash: String?, createdAtMs: Int64, modifiedAtMs: Int64) {
        self.id = id; self.name = name; self.folders = folders; self.startDate = startDate
        self.endDate = endDate; self.places = places; self.coverHash = coverHash
        self.createdAtMs = createdAtMs; self.modifiedAtMs = modifiedAtMs
    }

    // Encode nil as explicit JSON null so every key is present on disk (readers key on presence).
    private enum K: String, CodingKey {
        case id, name, folders, startDate, endDate, places, coverHash, createdAtMs, modifiedAtMs
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(folders, forKey: .folders)
        try c.encode(startDate, forKey: .startDate); try c.encode(endDate, forKey: .endDate)
        try c.encode(places, forKey: .places); try c.encode(coverHash, forKey: .coverHash)
        try c.encode(createdAtMs, forKey: .createdAtMs); try c.encode(modifiedAtMs, forKey: .modifiedAtMs)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        folders = try c.decode([String].self, forKey: .folders)
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        places = try c.decodeIfPresent([TravelPlace].self, forKey: .places)
        coverHash = try c.decodeIfPresent(String.self, forKey: .coverHash)
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        modifiedAtMs = try c.decode(Int64.self, forKey: .modifiedAtMs)
    }
}

/// `.openphoto/travels/settings.json`: the Travels folder (direct subfolders become trips when
/// `autoDiscover`), and the discovered subfolders the user removed (`hidden`).
public struct TravelSettings: Codable, Sendable, Equatable {
    public var travelsFolder: String?
    public var autoDiscover: Bool
    public var hidden: [String]
    public init(travelsFolder: String?, autoDiscover: Bool, hidden: [String]) {
        self.travelsFolder = travelsFolder; self.autoDiscover = autoDiscover; self.hidden = hidden
    }
    public static let defaults = TravelSettings(travelsFolder: nil, autoDiscover: true, hidden: [])

    private enum K: String, CodingKey { case travelsFolder, autoDiscover, hidden }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(travelsFolder, forKey: .travelsFolder)
        try c.encode(autoDiscover, forKey: .autoDiscover)
        try c.encode(hidden, forKey: .hidden)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        travelsFolder = try c.decodeIfPresent(String.self, forKey: .travelsFolder)
        autoDiscover = try c.decodeIfPresent(Bool.self, forKey: .autoDiscover) ?? true
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
    }
}
