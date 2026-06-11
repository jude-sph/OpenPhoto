import Foundation
import GRDB

extension Catalog {
    /// Store (replace) the perceptual hash for an asset.
    public func upsertPHash(hash: String, value: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO phash (hash, value) VALUES (?, ?)",
                           arguments: [hash, value])
        }
    }

    /// (hash, dirPath, dHash) for every photo with a phash, over the timeline union — so `dirPath`
    /// is per-instance and covers local ∪ drive-only. Feeds DuplicateGrouper's same-folder bucketing.
    public func phashRowsWithDirPath() throws -> [(hash: String, dirPath: String, value: Int64)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.hash AS hash, u.dirPath AS dirPath, p.value AS value
                FROM (\(Self.timelineSQL)) u JOIN phash p ON p.hash = u.hash
                """).map { ($0["hash"], $0["dirPath"], $0["value"]) }
        }
    }
}
