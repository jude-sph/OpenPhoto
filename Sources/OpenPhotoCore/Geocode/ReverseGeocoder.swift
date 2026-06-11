import Foundation

public struct Place: Sendable, Equatable {
    public let city: String
    public let region: String
    public let country: String
    public let countryCode: String
    public init(city: String, region: String, country: String, countryCode: String) {
        self.city = city; self.region = region; self.country = country; self.countryCode = countryCode
    }
}

/// Pure offline reverse-geocoder over an in-memory city list (the unit-tested heart — no network,
/// no CLGeocoder, no I/O). A simple 1°×1° lat/lon grid bucket + haversine nearest-city query.
public struct ReverseGeocoder: Sendable {
    public struct City: Sendable {
        public let name: String
        public let lat: Double
        public let lon: Double
        public let countryCode: String
        public let region: String
        public let country: String
        public init(name: String, lat: Double, lon: Double,
                    countryCode: String, region: String, country: String) {
            self.name = name; self.lat = lat; self.lon = lon
            self.countryCode = countryCode; self.region = region; self.country = country
        }
    }

    private let cities: [City]
    private let grid: [GridKey: [Int]]            // cell → indices into `cities`
    private struct GridKey: Hashable { let la: Int; let lo: Int }

    public var isLoaded: Bool { !cities.isEmpty }

    public init(cities: [City]) {
        self.cities = cities
        var g: [GridKey: [Int]] = [:]
        for (i, c) in cities.enumerated() {
            let key = GridKey(la: Int(floor(c.lat)), lo: Int(floor(c.lon)))
            g[key, default: []].append(i)
        }
        self.grid = g
    }

    /// Nearest city to (lat, lon) within `maxKilometers` → its Place, else nil.
    public func place(lat: Double, lon: Double, maxKilometers: Double = 250) -> Place? {
        guard !cities.isEmpty else { return nil }
        let la = Int(floor(lat)), lo = Int(floor(lon))
        var best = -1; var bestKm = Double.greatestFiniteMagnitude
        // Scan an expanding ring of cells (3×3, widening if empty) up to a cap that covers maxKm.
        var ring = 1
        while ring <= 4 {
            for dla in -ring...ring {
                for dlo in -ring...ring {
                    // Wrap longitude across the antimeridian.
                    let key = GridKey(la: la + dla, lo: wrapLon(lo + dlo))
                    for idx in grid[key] ?? [] {
                        let km = haversineKm(lat, lon, cities[idx].lat, cities[idx].lon)
                        if km < bestKm { bestKm = km; best = idx }
                    }
                }
            }
            if best >= 0 && bestKm <= Double(ring) * 111.0 { break }   // found within scanned radius
            ring += 1
        }
        guard best >= 0, bestKm <= maxKilometers else { return nil }
        let c = cities[best]
        return Place(city: c.name, region: c.region, country: c.country, countryCode: c.countryCode)
    }

    private func wrapLon(_ lo: Int) -> Int {
        var x = lo
        if x < -180 { x += 360 }; if x > 179 { x -= 360 }
        return x
    }

    private func haversineKm(_ lat1: Double, _ lon1: Double,
                              _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = 0.5 - cos((lat2 - lat1) * p) / 2
              + cos(lat1 * p) * cos(lat2 * p) * (1 - cos((lon2 - lon1) * p)) / 2
        return 2 * r * asin(min(1, sqrt(max(0, a))))
    }
}
