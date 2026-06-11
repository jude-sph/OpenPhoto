import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String, lat: Double? = nil, lon: Double? = nil) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: lat, longitude: lon, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let A = "sha256:" + String(repeating: "a", count: 64)   // near Taipei
private let C = "sha256:" + String(repeating: "c", count: 64)   // no GPS
private let O = "sha256:" + String(repeating: "0", count: 64)   // ocean

private func loadedStage() -> GeocodeStage {
    let geo = ReverseGeocoder(cities: [
        .init(name: "Taipei", lat: 25.03, lon: 121.57,
              countryCode: "TW", region: "Taipei", country: "Taiwan")])
    return GeocodeStage(geocoder: geo)            // test-only init taking a prebuilt geocoder
}

@Test func writesPlaceForGeotaggedPhoto() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, lat: 25.05, lon: 121.55)])
    let ok = await loadedStage().run(hash: A, url: t.root, catalog: cat)   // url ignored
    #expect(ok)
    #expect(try cat.geocode(forHash: A)?.city == "Taipei")
}

@Test func noGpsWritesNothingButSucceeds() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(C)])
    #expect(await loadedStage().run(hash: C, url: t.root, catalog: cat))    // success (nothing to do)
    #expect(try cat.geocode(forHash: C) == nil)
}

@Test func oceanWritesNothing() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(O, lat: -40, lon: -120)])
    #expect(await loadedStage().run(hash: O, url: t.root, catalog: cat))
    #expect(try cat.geocode(forHash: O) == nil)                            // no nearby city
}

@Test func availabilityTracksDataset() {
    #expect(loadedStage().isAvailable)                                     // loaded geocoder
    #expect(GeocodeStage(geocoder: ReverseGeocoder(cities: [])).isAvailable == false)  // empty → skip
}

@Test func absentDatasetStageIsNotAvailable() throws {
    // Pointing at a dir with no geonames files → isAvailable == false
    let t = try TestDirs(); defer { t.cleanup() }
    let stage = GeocodeStage(datasetDirectory: t.root)
    #expect(stage.isAvailable == false)
}
