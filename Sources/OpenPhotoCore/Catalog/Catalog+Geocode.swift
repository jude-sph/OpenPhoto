import Foundation
import GRDB

public struct GeocodeRow: Sendable, Equatable {
    public var hash: String
    public var city: String
    public var region: String
    public var country: String
    public var countryCode: String
    public init(hash: String, city: String, region: String, country: String, countryCode: String) {
        self.hash = hash; self.city = city; self.region = region
        self.country = country; self.countryCode = countryCode
    }
}

public struct PlaceFacet: Sendable, Equatable, Hashable {
    public let countryCode: String
    public let country: String
    public let city: String          // "" → a country-level facet
    public let count: Int
}

/// A lightweight geotagged-asset record for the Map surface (hash + GPS coords + timestamp).
public struct GeoAsset: Sendable, Equatable {
    public let hash: String
    public let lat: Double
    public let lon: Double
    public let takenAtMs: Int64
    public init(hash: String, lat: Double, lon: Double, takenAtMs: Int64) {
        self.hash = hash; self.lat = lat; self.lon = lon; self.takenAtMs = takenAtMs
    }
}

extension Catalog {
    /// Idempotent upsert of a resolved place for an asset.
    public func upsertGeocode(_ row: GeocodeRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO geocode (hash, city, region, country, countryCode) VALUES (?,?,?,?,?)
                ON CONFLICT(hash) DO UPDATE SET city=excluded.city, region=excluded.region,
                    country=excluded.country, countryCode=excluded.countryCode
                """, arguments: [row.hash, row.city, row.region, row.country, row.countryCode])
        }
    }

    /// The resolved place for one asset (for the inspector), or nil if not yet geocoded / no place.
    public func geocode(forHash hash: String) throws -> GeocodeRow? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT hash, city, region, country, countryCode FROM geocode WHERE hash = ?",
                arguments: [hash]) else { return nil }
            return GeocodeRow(hash: r["hash"], city: r["city"] ?? "", region: r["region"] ?? "",
                              country: r["country"] ?? "", countryCode: r["countryCode"] ?? "")
        }
    }

    /// (lat, lon) for an asset, or nil if either is null (no GPS). Geocode keys off this, not bytes.
    public func coordinate(forHash hash: String) throws -> (lat: Double, lon: Double)? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db,
                sql: "SELECT latitude, longitude FROM assets WHERE hash = ?", arguments: [hash]),
                  let lat = r["latitude"] as Double?, let lon = r["longitude"] as Double?
            else { return nil }
            return (lat, lon)
        }
    }

    /// Every asset with a GPS fix, for the Map surface. Photos without lat/lon are excluded.
    /// Locked photos are hidden from the map unless the session is revealed.
    public func geotaggedAssets() throws -> [GeoAsset] {
        let lvc = lockedVisibilityClause(hashColumn: "assets.hash")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, latitude, longitude, takenAtMs FROM assets
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND isLivePairedVideo = 0
                \(lvc)
                ORDER BY takenAtMs DESC
                """).map { GeoAsset(hash: $0["hash"], lat: $0["latitude"], lon: $0["longitude"],
                                    takenAtMs: $0["takenAtMs"]) }
        }
    }

    /// Distinct places in the library: a country-level facet per countryCode (city == "") plus a
    /// city-level facet per (countryCode, city), each with its asset count. For the Search picker.
    /// Locked photos are hidden unless the session is revealed.
    public func distinctPlaces() throws -> [PlaceFacet] {
        let lvc = lockedVisibilityClause(hashColumn: "geocode.hash")
        return try dbQueue.read { db in
            let byCountry = try Row.fetchAll(db, sql: """
                SELECT countryCode, country, COUNT(*) AS cnt FROM geocode
                WHERE countryCode <> '' \(lvc)
                GROUP BY countryCode ORDER BY country
                """).map { PlaceFacet(countryCode: $0["countryCode"], country: $0["country"] ?? "",
                                      city: "", count: $0["cnt"]) }
            let byCity = try Row.fetchAll(db, sql: """
                SELECT countryCode, country, city, COUNT(*) AS cnt FROM geocode
                WHERE city <> '' \(lvc)
                GROUP BY countryCode, city ORDER BY country, city
                """).map { PlaceFacet(countryCode: $0["countryCode"], country: $0["country"] ?? "",
                                      city: $0["city"], count: $0["cnt"]) }
            return byCountry + byCity
        }
    }
}
