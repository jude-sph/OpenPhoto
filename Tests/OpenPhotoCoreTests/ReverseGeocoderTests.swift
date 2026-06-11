import Testing
@testable import OpenPhotoCore

private func city(_ name: String, _ lat: Double, _ lon: Double,
                  _ cc: String, _ region: String, _ country: String) -> ReverseGeocoder.City {
    ReverseGeocoder.City(name: name, lat: lat, lon: lon,
                         countryCode: cc, region: region, country: country)
}

@Test func nearestCityWins() {
    let geo = ReverseGeocoder(cities: [
        city("Taipei", 25.03, 121.57, "TW", "Taipei", "Taiwan"),
        city("Tokyo", 35.68, 139.69, "JP", "Tokyo", "Japan"),
        city("Kaohsiung", 22.62, 120.31, "TW", "Kaohsiung", "Taiwan"),
    ])
    #expect(geo.isLoaded)
    let p = geo.place(lat: 25.05, lon: 121.55)        // right next to Taipei
    #expect(p?.city == "Taipei" && p?.country == "Taiwan" && p?.countryCode == "TW")
    let q = geo.place(lat: 22.60, lon: 120.30)        // near Kaohsiung
    #expect(q?.city == "Kaohsiung")
}

@Test func openOceanReturnsNil() {
    let geo = ReverseGeocoder(cities: [city("Taipei", 25.03, 121.57, "TW", "Taipei", "Taiwan")])
    #expect(geo.place(lat: -40.0, lon: -120.0) == nil)   // South Pacific — far from any city
}

@Test func emptyDatasetIsGracefullyEmpty() {
    let geo = ReverseGeocoder(cities: [])
    #expect(geo.isLoaded == false)
    #expect(geo.place(lat: 25.03, lon: 121.57) == nil)   // never crashes
}

@Test func resolvesAcrossAntimeridian() {
    // Two cities straddling ±180°; a query just east of the line must find the nearer one.
    let geo = ReverseGeocoder(cities: [
        city("Suva", -18.14, 178.44, "FJ", "Central", "Fiji"),
        city("Apia", -13.83, -171.77, "WS", "Tuamasaga", "Samoa"),
    ])
    let p = geo.place(lat: -18.10, lon: 178.50)
    #expect(p?.city == "Suva")
}
