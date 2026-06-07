import Foundation
import GRDB

extension Catalog {
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
    public func items(inDir dirPath: String) throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(
                db, sql: Self.timelineSQL + " AND i.dirPath = ? ORDER BY a.takenAtMs DESC",
                arguments: [dirPath])
        }
    }

    /// dirPath → item count, across all vaults (drives the folder tree).
    public func folderCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0 GROUP BY i.dirPath
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["d"] as String, $0["n"] as Int) })
        }
    }

    public func item(hash: String) throws -> TimelineItem? {
        try dbQueue.read { db in
            try TimelineItem.fetchOne(db, sql: Self.timelineSQL + " AND a.hash = ? LIMIT 1",
                                      arguments: [hash])
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
