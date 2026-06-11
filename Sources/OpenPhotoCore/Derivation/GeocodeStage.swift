import Foundation

/// The fourth background derivation stage: reverse-geocode a geotagged photo's GPS to a place
/// (offline, against the bundled GeoNames dataset). Unlike OCR/Embed/Faces it needs NO image bytes —
/// it reads the asset's stored lat/lon from the catalog. Graceful absence: an unloaded geocoder
/// (no dataset) → isAvailable == false → the runner skips the whole stage (jobs stay pending).
public final class GeocodeStage: @unchecked Sendable {
    public let id = "geocode"
    public let eligibleKind = "photo"
    private let geocoder: ReverseGeocoder

    /// Production init — lazily loads the dataset from the app bundle (or `datasetDirectory`).
    /// `datasetDirectory` should be the directory that *contains* the `geonames/` subfolder,
    /// or nil to use `Bundle.main.resourceURL` (where `make-app.sh` injects the dataset).
    public convenience init(datasetDirectory: URL? = nil) {
        let base = datasetDirectory ?? Bundle.main.resourceURL
        let dir = base?.appendingPathComponent("geonames")
        self.init(geocoder: GeoNamesLoader.load(directory: dir))
    }

    /// Test/explicit init — inject a prebuilt geocoder (synthetic city list in tests).
    public init(geocoder: ReverseGeocoder) { self.geocoder = geocoder }
}

extension GeocodeStage: DerivationStage {
    /// True iff the GeoNames dataset loaded. Absent → stage skipped (jobs pending), like EmbedStage.
    public var isAvailable: Bool { geocoder.isLoaded }

    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        // Geocode keys off the catalog's stored GPS, not the image bytes (url is ignored).
        // `try?` on an Optional-returning function yields Optional<Optional<T>> — flatten with `??`.
        guard let c = (try? catalog.coordinate(forHash: hash)) ?? nil else { return true }
        if let place = geocoder.place(lat: c.lat, lon: c.lon) {
            try? catalog.upsertGeocode(GeocodeRow(hash: hash, city: place.city, region: place.region,
                                                  country: place.country, countryCode: place.countryCode))
        }
        // Analyzed (place written, or no GPS / no nearby city) → success, never re-tried.
        return true
    }
}
