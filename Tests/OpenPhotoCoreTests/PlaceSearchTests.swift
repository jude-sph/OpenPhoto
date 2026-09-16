import Testing
@testable import OpenPhotoCore

private func e(_ id: Int, _ name: String, ascii: String? = nil, alt: [String] = [], pop: Int,
               _ lat: Double = 0, _ lon: Double = 0, cc: String = "JP", region: String = "R", country: String = "Japan") -> PlaceSearch.Entry {
    PlaceSearch.Entry(geonameID: id, name: name, asciiName: ascii ?? name, alternateNames: alt,
                      lat: lat, lon: lon, countryCode: cc, region: region, country: country, population: pop)
}
private let index = PlaceSearch(entries: [
    e(1, "Kyoto", pop: 1_400_000, 35.02, 135.75),
    e(2, "Kyōtango", ascii: "Kyotango", pop: 55_000),
    e(3, "Osaka", alt: ["Ōsaka", "Osaka-shi"], pop: 2_700_000),
    e(4, "Hội An", ascii: "Hoi An", pop: 120_000, cc: "VN", region: "Quảng Nam", country: "Vietnam"),
    e(5, "Paris", pop: 2_100_000, cc: "FR", region: "Île-de-France", country: "France"),
    e(6, "Paris", pop: 25_000, cc: "US", region: "Texas", country: "United States"),
])

@Test func suggestPrefixMatchesNameAsciiAndAlternates() {
    #expect(index.suggest("kyo").map(\.geonameID) == [1, 2])          // both, larger first
    #expect(index.suggest("hoi a").map(\.name) == ["Hội An"])           // ascii name, diacritics folded
    #expect(index.suggest("hội").map(\.name) == ["Hội An"])
    #expect(index.suggest("osaka-s").map(\.name) == ["Osaka"])          // alternate name
}

@Test func suggestExactNameFirstThenPopulation() {
    let out = index.suggest("paris")
    #expect(out.map(\.geonameID) == [5, 6])                             // both exact → population
    #expect(out[0].country == "France" && out[0].isOnMap && out[0].region == "Île-de-France")
    #expect(index.suggest("Kyot").map(\.geonameID) == [1, 2])
}

@Test func suggestLimitEmptyAndUnloaded() {
    #expect(index.suggest("p", limit: 1).count == 1)
    #expect(index.suggest("   ").isEmpty && index.suggest("zzz").isEmpty)
    #expect(PlaceSearch.empty.suggest("kyoto").isEmpty && !PlaceSearch.empty.isLoaded)
}

@Test func placeMatchingDetectedCityResolvesCoordinates() {
    let d = DetectedPlace(city: "Paris", region: "Texas", country: "United States", countryCode: "US", count: 3)
    let p = index.place(matching: d)
    #expect(p?.geonameID == 6 && p?.latitude == 0 && p?.country == "United States")
    // Same city name, no region match → fall back to the most populous in that country.
    let d2 = DetectedPlace(city: "Paris", region: "", country: "France", countryCode: "FR", count: 1)
    #expect(index.place(matching: d2)?.geonameID == 5)
    #expect(index.place(matching: DetectedPlace(city: "Atlantis", region: "", country: "", countryCode: "XX", count: 1)) == nil)
}

@Test func loaderParsesSearchFieldsFromDataset() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("geonames")
    let line = ["1857910", "Kyoto", "Kyoto", "Kioto,Kyōto", "35.02107", "135.75385", "P", "PPLA", "JP", "",
                "22", "", "", "", "1459640", "", "50", "Asia/Tokyo", "2023-01-01"].joined(separator: "\t")
    try (line + "\n").write(to: dir.appendingPathComponent("cities15000.txt"), atomically: true, encoding: .utf8)
    try "JP.22\tKyoto\tKyoto\t1\n".write(to: dir.appendingPathComponent("admin1CodesASCII.txt"), atomically: true, encoding: .utf8)
    try "#c\nJP\tJPN\t392\tJA\tJapan\tTokyo\n".write(to: dir.appendingPathComponent("countryInfo.txt"), atomically: true, encoding: .utf8)
    let (geo, search) = GeoNamesLoader.loadAll(directory: dir)
    #expect(geo.isLoaded && search.isLoaded)
    let k = try #require(search.suggest("kioto").first)
    #expect(k.geonameID == 1857910 && k.region == "Kyoto" && k.country == "Japan" && k.longitude == 135.75385)
}
