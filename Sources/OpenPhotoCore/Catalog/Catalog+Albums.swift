import Foundation
import GRDB

/// Sidebar/list view of an album: identity, name, cover, and a lock-gated member count.
public struct AlbumSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let coverHash: String?
    public let count: Int
    public init(id: String, name: String, coverHash: String?, count: Int) {
        self.id = id; self.name = name; self.coverHash = coverHash; self.count = count
    }
}

extension Catalog {
    // MARK: Mirror maintenance (rebuilt from the sovereign .openphoto/albums/*.json files)

    /// Rebuild the entire albums mirror from the loaded album files (open-time / external change).
    public func replaceAlbums(_ albums: [AlbumRecord]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM album_members")
            try db.execute(sql: "DELETE FROM albums")
            for a in albums { try Self.insertAlbum(a, db) }
        }
    }

    /// Insert-or-replace a single album + its ordered members (after one mutation).
    public func upsertAlbum(_ album: AlbumRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM album_members WHERE albumID = ?", arguments: [album.id])
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [album.id])
            try Self.insertAlbum(album, db)
        }
    }

    public func deleteAlbumMirror(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM album_members WHERE albumID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [id])
        }
    }

    private static func insertAlbum(_ a: AlbumRecord, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO albums (id, name, coverHash, createdAtMs, modifiedAtMs) VALUES (?, ?, ?, ?, ?)
            """, arguments: [a.id, a.name, a.coverHash, a.createdAtMs, a.modifiedAtMs])
        for (i, h) in a.members.enumerated() {
            // OR IGNORE dedups a hash that appears twice in the file (keeps its first position).
            try db.execute(sql: "INSERT OR IGNORE INTO album_members (albumID, hash, position) VALUES (?, ?, ?)",
                           arguments: [a.id, h, i])
        }
    }

    // MARK: Queries

    /// Photos in an album, in stored order, deduped by content and honoring the locked-folder gate
    /// (a member whose only instances are locked is hidden until the session is revealed).
    public func itemsInAlbum(id: String) throws -> [TimelineItem] {
        try dbQueue.read { db in
            let lvc = lockedVisibilityClause(hashColumn: "base.hash")
            return try TimelineItem.fetchAll(db, sql: """
                SELECT base.* FROM (\(Self.browseSQL)) base
                JOIN album_members m ON m.hash = base.hash
                WHERE m.albumID = ? \(lvc)
                ORDER BY m.position
                """, arguments: [id])
        }
    }

    /// All albums for the sidebar, with a lock-gated member count, sorted by name.
    public func albumSummaries() throws -> [AlbumSummary] {
        try dbQueue.read { db in
            let lvc = lockedVisibilityClause(hashColumn: "m.hash")
            // Effective cover = the explicit coverHash when it's a visible member, else the first
            // visible member by position (so the sidebar thumbnail never shows a locked-only photo).
            return try Row.fetchAll(db, sql: """
                SELECT al.id AS id, al.name AS name,
                  (SELECT m.hash FROM album_members m
                     JOIN assets a ON a.hash = m.hash AND a.isLivePairedVideo = 0
                     WHERE m.albumID = al.id \(lvc)
                     ORDER BY (CASE WHEN m.hash = al.coverHash THEN 0 ELSE 1 END), m.position
                     LIMIT 1) AS coverHash,
                  (SELECT COUNT(*) FROM album_members m
                     JOIN assets a ON a.hash = m.hash AND a.isLivePairedVideo = 0
                     WHERE m.albumID = al.id \(lvc)) AS cnt
                FROM albums al
                ORDER BY al.name COLLATE NOCASE
                """).map {
                    AlbumSummary(id: $0["id"], name: $0["name"], coverHash: $0["coverHash"], count: $0["cnt"])
                }
        }
    }

    /// The set of album ids that currently contain `hash` (for "Add to Album" ✓ marks).
    public func albumIDsContaining(hash: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT albumID FROM album_members WHERE hash = ?",
                                    arguments: [hash]))
        }
    }
}
