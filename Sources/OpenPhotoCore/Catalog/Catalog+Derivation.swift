import Foundation
import GRDB

extension Catalog {
    /// How many times a stage is retried on a per-asset failure before it's given up.
    static let maxDerivationAttempts = 3

    /// The asset kind a derivation stage applies to (v1: OCR → photos only).
    private static func eligibleKind(forStage stage: String) -> String {
        switch stage {
        case "ocr":     return "photo"
        case "embed":   return "photo"
        case "faces":   return "photo"
        case "geocode": return "photo"
        case "phash":   return "photo"
        default:        return "photo"
        }
    }

    /// Asset hashes still needing `stage` (no `done` job, and not over the retry cap), newest-first.
    /// `limit == nil` returns the whole pending set (the runner drains it all so an unreachable
    /// newest asset can't block older reachable ones behind a fixed top-N window).
    public func pendingDerivation(stage: String, limit: Int? = nil) throws -> [String] {
        let kind = Self.eligibleKind(forStage: stage)
        return try dbQueue.read { db in
            var sql = """
                SELECT a.hash FROM assets a
                LEFT JOIN derivation_jobs j ON j.hash = a.hash AND j.stage = ?
                WHERE a.kind = ? AND a.isLivePairedVideo = 0
                  AND (j.hash IS NULL OR (j.status = 'failed' AND j.attempts < ?))
                """
            if stage == "geocode" { sql += " AND a.latitude IS NOT NULL AND a.longitude IS NOT NULL" }
            sql += " ORDER BY a.takenAtMs DESC"
            if let limit { sql += " LIMIT \(limit)" }
            return try String.fetchAll(db, sql: sql,
                arguments: [stage, kind, Self.maxDerivationAttempts])
        }
    }

    /// Mark a stage complete for an asset (idempotent).
    public func markDerived(hash: String, stage: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO derivation_jobs (hash, stage, status, attempts, updatedAtMs)
                VALUES (?, ?, 'done', 0, ?)
                ON CONFLICT(hash, stage) DO UPDATE SET status='done', updatedAtMs=excluded.updatedAtMs
                """, arguments: [hash, stage, now])
        }
    }

    /// Drop all job rows for a stage so every eligible asset re-enters `pendingDerivation` — the
    /// trigger for a full re-derivation (e.g. the face rescan after a model change).
    public func clearDerivationJobs(stage: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM derivation_jobs WHERE stage = ?", arguments: [stage])
        }
    }

    /// Record a failed attempt (increments the attempt count).
    public func markDerivationFailed(hash: String, stage: String) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO derivation_jobs (hash, stage, status, attempts, updatedAtMs)
                VALUES (?, ?, 'failed', 1, ?)
                ON CONFLICT(hash, stage) DO UPDATE
                  SET status='failed', attempts = derivation_jobs.attempts + 1,
                      updatedAtMs = excluded.updatedAtMs
                """, arguments: [hash, stage, now])
        }
    }

    /// (done, total) for a stage — total = eligible-kind assets, done = `done` job rows.
    public func derivationProgress(stage: String) throws -> (done: Int, total: Int) {
        let kind = Self.eligibleKind(forStage: stage)
        return try dbQueue.read { db in
            let gps = stage == "geocode" ? " AND latitude IS NOT NULL AND longitude IS NOT NULL" : ""
            let total = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM assets WHERE kind = ? AND isLivePairedVideo = 0\(gps)",
                arguments: [kind]) ?? 0
            let done = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM derivation_jobs WHERE stage = ? AND status = 'done'",
                arguments: [stage]) ?? 0
            return (done, total)
        }
    }

    /// Replace the OCR text for an asset (FTS5 has no upsert → delete then insert).
    public func upsertOCR(hash: String, text: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ocr WHERE hash = ?", arguments: [hash])
            try db.execute(sql: "INSERT INTO ocr (hash, text) VALUES (?, ?)", arguments: [hash, text])
        }
    }

    /// Hashes whose OCR text matches `query` (FTS5), best-ranked first. Empty query → [].
    /// Locked photos are hidden from results unless the session is revealed.
    public func searchOCR(_ query: String) throws -> [String] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        // Each term as a quoted prefix query (escape embedded quotes), implicit-AND joined.
        let fts = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
                       .joined(separator: " ")
        let lvc = lockedVisibilityClause(hashColumn: "ocr.hash")
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT hash FROM ocr WHERE ocr MATCH ? \(lvc) ORDER BY rank",
                                arguments: [fts])
        }
    }
}
