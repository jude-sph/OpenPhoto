import Foundation

/// Forward lookup over the bundled GeoNames city list: type a place, get map-recognised
/// `TravelPlace`s (coordinates + GeoNames id). Pure and in-memory, no network. Matching is a
/// case- and diacritic-insensitive prefix match on the name, ASCII name, or any alternate name;
/// exact-name matches rank first, then by population. Absent dataset ⇒ `.empty` (no suggestions).
public struct PlaceSearch: Sendable {
    public struct Entry: Sendable {
        public let geonameID: Int
        public let name: String
        public let asciiName: String
        public let alternateNames: [String]
        public let lat: Double
        public let lon: Double
        public let countryCode: String
        public let region: String
        public let country: String
        public let population: Int
        public init(geonameID: Int, name: String, asciiName: String, alternateNames: [String], lat: Double, lon: Double,
                    countryCode: String, region: String, country: String, population: Int) {
            self.geonameID = geonameID; self.name = name; self.asciiName = asciiName; self.alternateNames = alternateNames
            self.lat = lat; self.lon = lon; self.countryCode = countryCode; self.region = region; self.country = country
            self.population = population
        }
    }

    private let entries: [Entry]
    private let keys: [[String]]          // folded name + ascii + alternates, per entry
    public static let empty = PlaceSearch(entries: [])
    public var isLoaded: Bool { !entries.isEmpty }

    public init(entries: [Entry]) {
        self.entries = entries
        self.keys = entries.map { e in
            var k = [Self.fold(e.name), Self.fold(e.asciiName)]
            k.append(contentsOf: e.alternateNames.map(Self.fold))
            return k
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func suggest(_ query: String, limit: Int = 8) -> [TravelPlace] {
        let q = Self.fold(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        var hits: [(exact: Bool, pop: Int, idx: Int)] = []
        for (i, ks) in keys.enumerated() {
            var exact = false, prefix = false
            for k in ks where k.hasPrefix(q) { prefix = true; if k == q { exact = true; break } }
            if prefix { hits.append((exact, entries[i].population, i)) }
        }
        hits.sort { a, b in
            if a.exact != b.exact { return a.exact }
            if a.pop != b.pop { return a.pop > b.pop }
            return entries[a.idx].name < entries[b.idx].name
        }
        return hits.prefix(limit).map { Self.place(entries[$0.idx]) }
    }

    /// Resolve a detected city (a `geocode` row) to its entry: same country + name; prefer the same
    /// region, else the most populous. Nil if the dataset has no such city.
    public func place(matching d: DetectedPlace) -> TravelPlace? {
        let name = Self.fold(d.city), region = Self.fold(d.region)
        let candidates = entries.enumerated().filter { $0.element.countryCode == d.countryCode && keys[$0.offset][0] == name }
        guard !candidates.isEmpty else { return nil }
        if let same = candidates.first(where: { Self.fold($0.element.region) == region && !region.isEmpty }) {
            return Self.place(same.element)
        }
        return Self.place(candidates.max { $0.element.population < $1.element.population }!.element)
    }

    static func place(_ e: Entry) -> TravelPlace {
        TravelPlace(name: e.name, region: e.region.isEmpty ? nil : e.region, country: e.country.isEmpty ? nil : e.country,
                    countryCode: e.countryCode, latitude: e.lat, longitude: e.lon, geonameID: e.geonameID)
    }
}
