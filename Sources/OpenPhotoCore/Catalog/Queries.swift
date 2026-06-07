import Foundation
import GRDB

extension Catalog {
    // One row per INSTANCE: an asset present in two vaults appears twice — intentional v1;
    // dedup review handles duplicates (phase 5).
    private static let timelineSQL = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight,
               a.latitude, a.longitude, a.cameraModel, a.lensModel, a.durationSeconds,
               a.livePairHash, a.favorite, a.rating, a.caption, a.tagsJSON,
               i.vaultID, i.relPath, i.dirPath, i.size
        FROM assets a
        JOIN instances i ON i.hash = a.hash
        WHERE a.isLivePairedVideo = 0
        """

    /// Whole-library browse rows, newest first. ~60k rows fetch in tens of ms.
    public func timelineItems() throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(db, sql: Self.timelineSQL + " ORDER BY a.takenAtMs DESC")
        }
    }

    /// Items whose instance lives in the given folder (non-recursive).
    /// - Parameter vaultID: when non-nil, restricts to that vault; nil = union across vaults.
    public func items(inDir dirPath: String, vaultID: String? = nil) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var sql = Self.timelineSQL + " AND i.dirPath = ?"
            var args: [DatabaseValueConvertible] = [dirPath]
            if let vid = vaultID {
                sql += " AND i.vaultID = ?"
                args.append(vid)
            }
            sql += " ORDER BY a.takenAtMs DESC"
            return try TimelineItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// dirPath → item count.
    /// - Parameter vaultID: when non-nil, restricts to that vault; nil = union across vaults.
    public func folderCounts(vaultID: String? = nil) throws -> [String: Int] {
        try dbQueue.read { db in
            var sql = """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0
                """
            var args: [DatabaseValueConvertible] = []
            if let vid = vaultID {
                sql += " AND i.vaultID = ?"
                args.append(vid)
            }
            sql += " GROUP BY i.dirPath"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["d"] as String, $0["n"] as Int) })
        }
    }

    public func item(hash: String) throws -> TimelineItem? {
        try dbQueue.read { db in
            try TimelineItem.fetchOne(db, sql: Self.timelineSQL + " AND a.hash = ? LIMIT 1",
                                      arguments: [hash])
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
