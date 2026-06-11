import Foundation
import GRDB

extension Catalog {
    // MARK: – Structured filter

    /// Return hashes that match all active structured filters, newest-first.
    /// Uses the timeline union (local instances ∪ drive-only) so results match what the grid shows.
    /// tags are AND-ed: an asset must carry every requested tag (json_each approach).
    public func structuredFilter(_ filters: SearchFilters) throws -> [String] {
        try dbQueue.read { db in
            // Build WHERE clauses over the timeline union.
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let range = filters.dateRange {
                conditions.append("takenAtMs >= ? AND takenAtMs <= ?")
                args.append(Int64(range.lowerBound.timeIntervalSince1970 * 1000))
                args.append(Int64(range.upperBound.timeIntervalSince1970 * 1000))
            }
            if let camera = filters.includeCameras.first {
                conditions.append("cameraModel = ?")
                args.append(camera)
            }
            if let minRating = filters.minRating, minRating > 0 {
                conditions.append("rating >= ?")
                args.append(minRating)
            }
            if filters.favoritesOnly {
                conditions.append("favorite = 1")
            }
            if filters.kind == .video {
                conditions.append("kind = 'video'")
            }

            // Tags AND: use json_each to check every requested tag is present in tagsJSON.
            // We need the asset to contain ALL requested tags.
            // Strategy: for each required tag, the asset's tagsJSON must include it.
            // Use subquery: every tag must match at least one json_each value.
            for tag in filters.includeTags {
                conditions.append("""
                    EXISTS (SELECT 1 FROM json_each(tagsJSON) WHERE json_each.value = ?)
                    """)
                args.append(tag)
            }

            // Person filter: restrict to assets that have a confirmed face row for that personID.
            if let person = filters.includePeople.first {
                conditions.append("hash IN (SELECT hash FROM faces WHERE personID = ?)")
                args.append(person)
            }

            // Place filter: restrict to assets with a geocode row matching the country/city.
            if let place = filters.includePlaces.first {
                switch place {
                case .country(let cc):
                    conditions.append("hash IN (SELECT hash FROM geocode WHERE countryCode = ?)")
                    args.append(cc)
                case .city(let cc, let city):
                    conditions.append("hash IN (SELECT hash FROM geocode WHERE countryCode = ? AND city = ?)")
                    args.append(cc); args.append(city)
                }
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT hash FROM (\(Self.timelineSQL))
                \(whereClause)
                ORDER BY takenAtMs DESC
                """
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: – Text matches

    /// Hashes that match the text query in OCR text, captions, or tags.
    /// OCR (FTS5-ranked) results come first; caption/tag LIKE matches appended, de-duped.
    public func textMatches(_ query: String) throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []

        // OCR lane (FTS5 ranked — best signal, OCR-rank order preserved)
        let ocrHits = (try? searchOCR(query)) ?? []
        for h in ocrHits where seen.insert(h).inserted { out.append(h) }

        // Caption + tag LIKE lane
        let term = "%" + query.replacingOccurrences(of: "%", with: "\\%")
                              .replacingOccurrences(of: "_", with: "\\_") + "%"
        let likeSql = """
            SELECT DISTINCT hash FROM assets
            WHERE (caption LIKE ? ESCAPE '\\')
               OR EXISTS (SELECT 1 FROM json_each(tagsJSON)
                          WHERE json_each.value LIKE ? ESCAPE '\\')
            """
        let likeHits = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: likeSql, arguments: [term, term])
        }) ?? []
        for h in likeHits where seen.insert(h).inserted { out.append(h) }

        return out
    }

    // MARK: – Distinct facets

    /// All distinct (non-nil) camera models in the catalog.
    public func distinctCameras() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT DISTINCT cameraModel FROM assets WHERE cameraModel IS NOT NULL ORDER BY cameraModel")
        }
    }

    /// All distinct tags across all assets, extracted via json_each.
    public func distinctTags() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT json_each.value FROM assets, json_each(tagsJSON)
                WHERE json_each.value IS NOT NULL AND json_each.value != ''
                ORDER BY json_each.value
                """)
        }
    }

    // MARK: – Items for hash list

    /// Fetch TimelineItems for the given hashes. When `preservingOrder` is true, reorders
    /// the result in Swift to match the input order (SQL IN(...) has no order guarantee).
    public func items(forHashes hashes: [String], preservingOrder: Bool) throws -> [TimelineItem] {
        guard !hashes.isEmpty else { return [] }
        return try dbQueue.read { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            let sql = """
                SELECT * FROM (\(Self.timelineSQL))
                WHERE hash IN (\(marks))
                """
            let rows = try TimelineItem.fetchAll(db, sql: sql,
                                                 arguments: StatementArguments(hashes))
            guard preservingOrder else { return rows }
            // Re-order to match the caller's hash order (each hash appears once;
            // if a hash has multiple instances take the first encountered).
            var byHash: [String: TimelineItem] = [:]
            for row in rows where byHash[row.hash] == nil { byHash[row.hash] = row }
            return hashes.compactMap { byHash[$0] }
        }
    }

    // MARK: – All hashes (needed by runSearch when filters are empty but query is not)

    /// All asset hashes in timeline order (newest first). Used by runSearch as the
    /// "no structured constraints" pass so the intersection with semantic is a no-op.
    public func allHashesNewestFirst() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT hash FROM (\(Self.timelineSQL)) ORDER BY takenAtMs DESC")
        }
    }
}
