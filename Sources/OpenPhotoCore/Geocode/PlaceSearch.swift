import Foundation

/// Forward lookup over the bundled GeoNames city list: type a place, get map-recognised
/// `TravelPlace`s (coordinates + GeoNames id). Pure and in-memory, no network. Matching is a
/// case- and diacritic-insensitive prefix match on the name, ASCII name, or any alternate name;
/// exact-name matches rank first, then by population. Every name is folded once at load and indexed
/// by folded key, so resolving a detected city is a dictionary lookup, not a scan. Absent dataset ⇒
/// `.empty` (no suggestions).
public struct PlaceSearch: Sendable {
    public struct Entry: Sendable {
        public let geonameID: Int
        public let name: String
        public let asciiName: String
        public let lat: Double
        public let lon: Double
        public let countryCode: String
        public let region: String
        public let country: String
        public let population: Int
        /// The folded (case/diacritic-insensitive) name, ascii name and alternate names — all this
        /// type ever matches on. The raw alternates are dropped after folding: nothing reads them,
        /// and the dataset carries tens of them per city.
        let foldedNames: [String]
        public init(geonameID: Int, name: String, asciiName: String, alternateNames: [String], lat: Double, lon: Double,
                    countryCode: String, region: String, country: String, population: Int) {
            self.geonameID = geonameID; self.name = name; self.asciiName = asciiName
            self.lat = lat; self.lon = lon; self.countryCode = countryCode; self.region = region; self.country = country
            self.population = population
            var seen = Set<String>()
            self.foldedNames = ([name, asciiName] + alternateNames).map(PlaceSearch.fold)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    private let entries: [Entry]
    private let byName: [String: [Int]]   // folded name (incl. ascii + alternates) → entry indices
    public static let empty = PlaceSearch(entries: [])
    public var isLoaded: Bool { !entries.isEmpty }

    public init(entries: [Entry]) {
        self.entries = entries
        var idx: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { for k in e.foldedNames { idx[k, default: []].append(i) } }
        self.byName = idx
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func suggest(_ query: String, limit: Int = 8) -> [TravelPlace] {
        let q = Self.fold(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        var hits: [(exact: Bool, pop: Int, idx: Int)] = []
        for (i, e) in entries.enumerated() {
            var exact = false, prefix = false
            for k in e.foldedNames where k.hasPrefix(q) { prefix = true; if k == q { exact = true; break } }
            if prefix { hits.append((exact, e.population, i)) }
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
        // One dictionary hit instead of a scan of the whole dataset — this runs once per detected
        // city of every trip on each Travels refresh.
        let candidates = (byName[name] ?? []).map { entries[$0] }.filter { $0.countryCode == d.countryCode }
        guard !candidates.isEmpty else { return nil }
        if !region.isEmpty, let same = candidates.first(where: { Self.fold($0.region) == region }) {
            return Self.place(same)
        }
        return Self.place(candidates.max { $0.population < $1.population }!)
    }

    static func place(_ e: Entry) -> TravelPlace {
        TravelPlace(name: e.name, region: e.region.isEmpty ? nil : e.region, country: e.country.isEmpty ? nil : e.country,
                    countryCode: e.countryCode, latitude: e.lat, longitude: e.lon, geonameID: e.geonameID)
    }
}
