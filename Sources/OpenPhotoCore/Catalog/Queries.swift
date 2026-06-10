import Foundation
import GRDB

extension Catalog {
    // Local branch: one row per INSTANCE (asset present in a local vault).
    // Assets in two vaults appear twice — intentional v1; dedup review handles duplicates (phase 5).
    // Selects NULL for driveRelPath because local instances always have a reachable file.
    private static let localSelect = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, i.vaultID, i.relPath, i.dirPath, i.size, NULL AS driveRelPath
        FROM assets a JOIN instances i ON i.hash = a.hash
        WHERE a.isLivePairedVideo = 0
        """

    // Drive-only branch: one row per asset that has NO local instance.
    // Deduped to one drive row per asset via MIN(rowid) when the asset is present on multiple drives.
    private static let driveSelect = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, vp.vaultID, vp.relPath, vp.dirPath, vp.size, vp.driveRelPath
        FROM assets a JOIN vault_presence vp ON vp.hash = a.hash
        WHERE a.isLivePairedVideo = 0
          AND NOT EXISTS (SELECT 1 FROM instances i WHERE i.hash = a.hash)
          AND vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.hash = a.hash)
        """

    // Full union: local rows (with NULL driveRelPath) UNION ALL drive-only rows.
    private static var timelineSQL: String { "\(localSelect) UNION ALL \(driveSelect)" }

    /// Whole-library browse rows, newest first. `videoOnly` restricts to videos.
    public func timelineItems(videoOnly: Bool = false) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM (\(Self.timelineSQL))"
            if videoOnly { sql += " WHERE kind = 'video'" }
            sql += " ORDER BY takenAtMs DESC"
            return try TimelineItem.fetchAll(db, sql: sql)
        }
    }

    /// Items whose instance lives in the given folder (non-recursive).
    /// - Parameter vaultID: when non-nil, restricts to that vault; nil = union across vaults.
    public func items(inDir dirPath: String, vaultID: String? = nil) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM (\(Self.timelineSQL)) WHERE dirPath = ?"
            var args: [DatabaseValueConvertible] = [dirPath]
            if let vid = vaultID {
                sql += " AND vaultID = ?"
                args.append(vid)
            }
            sql += " ORDER BY takenAtMs DESC"
            return try TimelineItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// dirPath → item count (local instances + drive-only assets, Mac-folder-aligned).
    /// - Parameter vaultID: when non-nil, restricts to that local vault; drive-only branch is
    ///   only included when vaultID is nil (drive-only assets have no local vaultID).
    public func folderCounts(vaultID: String? = nil) throws -> [String: Int] {
        try dbQueue.read { db in
            // Local branch
            var counts: [String: Int] = [:]
            var sql = """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0
                """
            var args: [DatabaseValueConvertible] = []
            if let v = vaultID {
                sql += " AND i.vaultID = ?"
                args.append(v)
            }
            sql += " GROUP BY i.dirPath"
            for r in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                counts[r["d"], default: 0] += (r["n"] as Int)
            }
            // Drive-only branch (only when not restricted to a local vault)
            if vaultID == nil {
                let dsql = """
                    SELECT vp.dirPath AS d, COUNT(*) AS n FROM vault_presence vp
                    JOIN assets a ON a.hash = vp.hash
                    WHERE a.isLivePairedVideo = 0
                      AND NOT EXISTS (SELECT 1 FROM instances i WHERE i.hash = vp.hash)
                      AND vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.hash = vp.hash)
                    GROUP BY vp.dirPath
                    """
                for r in try Row.fetchAll(db, sql: dsql) {
                    counts[r["d"], default: 0] += (r["n"] as Int)
                }
            }
            return counts
        }
    }

    public func item(hash: String) throws -> TimelineItem? {
        try dbQueue.read { db in
            try TimelineItem.fetchOne(db,
                sql: "SELECT * FROM (\(Self.timelineSQL)) WHERE hash = ? LIMIT 1",
                arguments: [hash])
        }
    }

    /// All local instances of an asset (across vaults) — for presence/Locations.
    public func instances(forHash hash: String) throws -> [InstanceRecord] {
        try dbQueue.read { db in
            try InstanceRecord.fetchAll(db, sql: "SELECT * FROM instances WHERE hash = ?",
                                        arguments: [hash])
        }
    }

    /// Lightweight instance lookup (Live Photo pair resolution, viewer).
    public func instanceItem(hash: String, vaultID: String) throws -> InstanceRecord? {
        try dbQueue.read { db in
            try InstanceRecord.fetchOne(db, sql:
                "SELECT * FROM instances WHERE hash = ? AND vaultID = ? LIMIT 1",
                arguments: [hash, vaultID])
        }
    }

    /// Record a Live Photo pairing on already-cataloged assets (scanner healing).
    public func setLivePair(photoHash: String, videoHash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET livePairHash = ? WHERE hash = ?",
                           arguments: [videoHash, photoHash])
            try db.execute(sql: "UPDATE assets SET isLivePairedVideo = 1 WHERE hash = ?",
                           arguments: [videoHash])
        }
    }

    /// Mirror a sidecar edit into the catalog (sidecar written separately).
    /// True if an instance with this hash already exists in the given folder of the vault.
    public func hashPresent(inVault vaultID: String, dirPath: String, hash: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM instances
                              WHERE hash = ? AND vaultID = ? AND dirPath = ?)
                """, arguments: [hash, vaultID, dirPath]) ?? false
        }
    }

    public func updateHumanMetadata(hash: String, favorite: Bool, rating: Int,
                                    caption: String?, tagsJSON: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET favorite = ?, rating = ?, caption = ?, tagsJSON = ?
                WHERE hash = ?
                """, arguments: [favorite, rating, caption, tagsJSON, hash])
        }
    }
}
