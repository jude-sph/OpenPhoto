import Foundation
import GRDB

extension Catalog {
    // MARK: – Structured filter

    /// Return hashes that match all active structured filters, newest-first.
    /// Uses the timeline union (local instances ∪ drive-only) so results match what the grid shows.
    /// tags are AND-ed: an asset must carry every requested tag (json_each approach).
    public func structuredFilter(_ filters: SearchFilters) throws -> [String] {
        try dbQueue.read { db in
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let range = filters.dateRange {
                conditions.append("takenAtMs >= ? AND takenAtMs <= ?")
                args.append(Int64(range.lowerBound.timeIntervalSince1970 * 1000))
                args.append(Int64(range.upperBound.timeIntervalSince1970 * 1000))
            }
            if let minRating = filters.minRating, minRating > 0 {
                conditions.append("rating >= ?"); args.append(minRating)
            }
            if filters.favoritesOnly { conditions.append("favorite = 1") }
            if let kind = filters.kind {
                switch kind {
                case .photo: conditions.append("kind = 'photo' AND livePairHash IS NULL")
                case .video: conditions.append("kind = 'video'")
                case .live:  conditions.append("livePairHash IS NOT NULL")
                }
            }
            if !filters.includeCameras.isEmpty {
                let marks = databaseQuestionMarks(count: filters.includeCameras.count)
                conditions.append("cameraModel IN (\(marks))")
                args.append(contentsOf: filters.includeCameras as [DatabaseValueConvertible])
            }
            if !filters.excludeCameras.isEmpty {
                let marks = databaseQuestionMarks(count: filters.excludeCameras.count)
                conditions.append("(cameraModel IS NULL OR cameraModel NOT IN (\(marks)))")
                args.append(contentsOf: filters.excludeCameras as [DatabaseValueConvertible])
            }
            func folderClause(_ folder: String) -> (sql: String, args: [DatabaseValueConvertible]) {
                let f = folder.precomposedStringWithCanonicalMapping
                return filters.foldersRecursive
                    ? ("(dirPath = ? OR dirPath GLOB ?)", [f, f + "/*"])
                    : ("dirPath = ?", [f])
            }
            if !filters.includeFolders.isEmpty {
                var ors: [String] = []
                for f in filters.includeFolders {
                    let c = folderClause(f); ors.append(c.sql); args.append(contentsOf: c.args)
                }
                conditions.append("(" + ors.joined(separator: " OR ") + ")")
            }
            for f in filters.excludeFolders {
                let c = folderClause(f); conditions.append("NOT \(c.sql)"); args.append(contentsOf: c.args)
            }
            for tag in filters.includeTags {
                conditions.append("EXISTS (SELECT 1 FROM json_each(tagsJSON) WHERE json_each.value = ?)")
                args.append(tag)
            }
            for tag in filters.excludeTags {
                conditions.append("NOT EXISTS (SELECT 1 FROM json_each(tagsJSON) WHERE json_each.value = ?)")
                args.append(tag)
            }
            for p in filters.includePeople {
                conditions.append("hash IN (SELECT hash FROM faces WHERE personID = ?)")
                args.append(p)
            }
            if !filters.excludePeople.isEmpty {
                let marks = databaseQuestionMarks(count: filters.excludePeople.count)
                conditions.append("hash NOT IN (SELECT hash FROM faces WHERE personID IN (\(marks)))")
                args.append(contentsOf: filters.excludePeople as [DatabaseValueConvertible])
            }
            switch filters.peoplePresence {
            case .has?:     conditions.append("hash IN (SELECT hash FROM faces)")
            case .without?: conditions.append("hash NOT IN (SELECT hash FROM faces)")
            case nil:       break
            }
            func placePredicate(_ p: PlaceFilter) -> (sql: String, args: [DatabaseValueConvertible]) {
                switch p {
                case .country(let cc):        return ("countryCode = ?", [cc])
                case .city(let cc, let city): return ("(countryCode = ? AND city = ?)", [cc, city])
                }
            }
            if !filters.includePlaces.isEmpty {
                var ors: [String] = []
                for p in filters.includePlaces { let c = placePredicate(p); ors.append(c.sql); args.append(contentsOf: c.args) }
                conditions.append("hash IN (SELECT hash FROM geocode WHERE \(ors.joined(separator: " OR ")))")
            }
            if !filters.excludePlaces.isEmpty {
                var ors: [String] = []
                for p in filters.excludePlaces { let c = placePredicate(p); ors.append(c.sql); args.append(contentsOf: c.args) }
                conditions.append("hash NOT IN (SELECT hash FROM geocode WHERE \(ors.joined(separator: " OR ")))")
            }
            if filters.hasText {
                conditions.append("hash IN (SELECT hash FROM ocr WHERE text <> '')")
            }

            // Lock filter: exclude locked-folder hashes when not revealed.
            let lf = lockedFilter
            if !lf.isEmpty { conditions.append("locked = 0") }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT hash FROM (\(Self.browseSQL))
                \(whereClause)
                ORDER BY takenAtMs DESC
                """
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: – Text matches

    /// Hashes that match the text query in OCR text, captions, or tags.
    /// OCR (FTS5-ranked) results come first; caption/tag LIKE matches appended, de-duped.
    /// Locked photos are hidden from results unless the session is revealed.
    public func textMatches(_ query: String) throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []

        // OCR lane (FTS5 ranked — best signal, OCR-rank order preserved; already lock-filtered)
        let ocrHits = (try? searchOCR(query)) ?? []
        for h in ocrHits where seen.insert(h).inserted { out.append(h) }

        // Caption + tag LIKE lane
        let term = "%" + query.replacingOccurrences(of: "%", with: "\\%")
                              .replacingOccurrences(of: "_", with: "\\_") + "%"
        let lvc = lockedVisibilityClause(hashColumn: "assets.hash")
        let likeSql = """
            SELECT DISTINCT hash FROM assets
            WHERE ((caption LIKE ? ESCAPE '\\')
               OR EXISTS (SELECT 1 FROM json_each(tagsJSON)
                          WHERE json_each.value LIKE ? ESCAPE '\\'))
            \(lvc)
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
    /// Locked photos are hidden from results unless the session is revealed.
    public func items(forHashes hashes: [String], preservingOrder: Bool) throws -> [TimelineItem] {
        guard !hashes.isEmpty else { return [] }
        let lf = lockedFilter
        let lockClause = lf.isEmpty ? "" : " AND locked = 0"
        return try dbQueue.read { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            let sql = """
                SELECT * FROM (\(Self.browseSQL))
                WHERE hash IN (\(marks))\(lockClause)
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
    /// Locked photos are hidden unless revealed.
    public func allHashesNewestFirst() throws -> [String] {
        let lf = lockedFilter
        let lockClause = lf.isEmpty ? "" : " WHERE locked = 0"
        return try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT hash FROM (\(Self.browseSQL))\(lockClause) ORDER BY takenAtMs DESC")
        }
    }
}
