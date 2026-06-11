import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String, lat: Double? = nil, lon: Double? = nil,
                   takenAtMs: Int64 = 1) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: lat, longitude: lon, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let A = "sha256:" + String(repeating: "a", count: 64)   // geotagged
private let B = "sha256:" + String(repeating: "b", count: 64)   // geotagged
private let C = "sha256:" + String(repeating: "c", count: 64)   // NO gps

@Test func upsertAndReadGeocode() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, lat: 25.03, lon: 121.57)])
    #expect(try cat.geocode(forHash: A) == nil)                      // not yet geocoded
    try cat.upsertGeocode(GeocodeRow(hash: A, city: "Taipei", region: "Taipei",
                                     country: "Taiwan", countryCode: "TW"))
    let g = try #require(try cat.geocode(forHash: A))
    #expect(g.city == "Taipei" && g.country == "Taiwan" && g.countryCode == "TW")
    // Idempotent re-upsert replaces.
    try cat.upsertGeocode(GeocodeRow(hash: A, city: "Taipei City", region: "Taipei",
                                     country: "Taiwan", countryCode: "TW"))
    #expect(try cat.geocode(forHash: A)?.city == "Taipei City")
}

@Test func distinctPlacesReturnsCountryAndCityFacets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, lat: 25, lon: 121), photo(B, lat: 35, lon: 139)])
    try cat.upsertGeocode(GeocodeRow(hash: A, city: "Taipei", region: "Taipei",
                                     country: "Taiwan", countryCode: "TW"))
    try cat.upsertGeocode(GeocodeRow(hash: B, city: "Tokyo", region: "Tokyo",
                                     country: "Japan", countryCode: "JP"))
    let facets = try cat.distinctPlaces()
    // Country-level facets (city == "") for TW and JP, each count 1; plus the two city facets.
    #expect(facets.contains(where: { $0.countryCode == "TW" && $0.city == "" && $0.count == 1 }))
    #expect(facets.contains(where: { $0.countryCode == "JP" && $0.city == "" && $0.count == 1 }))
    #expect(facets.contains(where: { $0.countryCode == "TW" && $0.city == "Taipei" && $0.count == 1 }))
}

@Test func coordinateReadsLatLon() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, lat: 25.03, lon: 121.57), photo(C)])
    let c = try #require(try cat.coordinate(forHash: A))
    #expect(abs(c.lat - 25.03) < 1e-9 && abs(c.lon - 121.57) < 1e-9)
    #expect(try cat.coordinate(forHash: C) == nil)            // no GPS → nil
}

@Test func geocodePendingIsGpsGated() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, lat: 25, lon: 121, takenAtMs: 2),
                            photo(C, takenAtMs: 1)])               // C has no GPS
    #expect(try cat.pendingDerivation(stage: "geocode") == [A])   // only the geotagged photo
    let prog = try cat.derivationProgress(stage: "geocode")
    #expect(prog.total == 1)                                       // total counts only geotagged
}
