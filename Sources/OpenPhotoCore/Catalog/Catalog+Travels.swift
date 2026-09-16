import Foundation
import GRDB

/// A city detected among a trip's photos (from the rebuildable `geocode` table), with its photo count.
public struct DetectedPlace: Sendable, Equatable {
    public let city: String
    public let region: String
    public let country: String
    public let countryCode: String
    public let count: Int
    public init(city: String, region: String, country: String, countryCode: String, count: Int) {
        self.city = city; self.region = region; self.country = country; self.countryCode = countryCode; self.count = count
    }
}

/// Derived facts for a trip = a set of folders, each with its whole subtree. Read-only aggregates
/// over the per-instance browse rows, honouring the locked-folder gate exactly like
/// `items(inDir:recursive:)`. Nothing here is stored — trips derive these at display time.
extension Catalog {
    /// "(dirPath = ? OR dirPath GLOB ?) OR (…)" for every path, with its arguments. GLOB "<p>/*"
    /// matches only paths under "<p>/" so a sibling like "Japan 2026x" never matches "Japan 2026".
    private static func dirClause(_ dirPaths: [String]) -> (sql: String, args: [DatabaseValueConvertible]) {
        var parts: [String] = []; var args: [DatabaseValueConvertible] = []
        for p in dirPaths { parts.append("(dirPath = ? OR dirPath GLOB ?)"); args.append(p); args.append(p + "/*") }
        return (parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")", args)
    }

    public func travelStats(dirPaths: [String]) throws -> TravelStats {
        guard !dirPaths.isEmpty else { return TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil) }
        let (clause, args) = Self.dirClause(dirPaths)
        return try dbQueue.read { db in
            let base = "SELECT * FROM (\(Self.instanceSQL)) WHERE \(clause) \(lockedFilter)"
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, MIN(takenAtMs) AS mn, MAX(takenAtMs) AS mx FROM (\(base))
                """, arguments: StatementArguments(args))
            let n: Int = row?["n"] ?? 0
            guard n > 0 else { return TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil) }
            let earliest = try String.fetchOne(db, sql: "SELECT hash FROM (\(base)) ORDER BY takenAtMs ASC, hash ASC LIMIT 1",
                                               arguments: StatementArguments(args))
            return TravelStats(count: n, minTakenAtMs: row?["mn"], maxTakenAtMs: row?["mx"], earliestHash: earliest)
        }
    }

    /// Distinct cities among the trip's photos, most photos first (ties by countryCode, then city).
    public func travelPlaces(dirPaths: [String]) throws -> [DetectedPlace] {
        guard !dirPaths.isEmpty else { return [] }
        let (clause, args) = Self.dirClause(dirPaths)
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.city, g.region, g.country, g.countryCode, COUNT(*) AS cnt
                FROM (SELECT hash FROM (\(Self.instanceSQL)) WHERE \(clause) \(lockedFilter)) b
                JOIN geocode g ON g.hash = b.hash
                WHERE g.city <> ''
                GROUP BY g.countryCode, g.city, g.region
                ORDER BY cnt DESC, g.countryCode ASC, g.city ASC
                """, arguments: StatementArguments(args)).map {
                DetectedPlace(city: $0["city"], region: $0["region"], country: $0["country"],
                              countryCode: $0["countryCode"], count: $0["cnt"])
            }
        }
    }

    /// The trip's photos, oldest first, one row per physical instance, de-duplicated by instanceID
    /// (a folder listed twice, or nested twice, contributes each file once).
    public func travelItems(dirPaths: [String]) throws -> [TimelineItem] {
        guard !dirPaths.isEmpty else { return [] }
        let (clause, args) = Self.dirClause(dirPaths)
        let rows = try dbQueue.read { db in
            try TimelineItem.fetchAll(db, sql: """
                SELECT * FROM (\(Self.instanceSQL)) WHERE \(clause) \(lockedFilter) ORDER BY takenAtMs ASC, hash ASC
                """, arguments: StatementArguments(args))
        }
        var seen = Set<String>(); return rows.filter { seen.insert($0.instanceID).inserted }
    }
}
