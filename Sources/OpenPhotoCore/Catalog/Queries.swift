import Foundation
import GRDB

extension Catalog {
    // Local branch: one row per INSTANCE (asset present in a local vault).
    // Assets in two vaults appear twice — intentional v1; dedup review handles duplicates (phase 5).
    // Selects NULL for driveRelPath because local instances always have a reachable file.
    private static let localSelect = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, a.rotation, i.vaultID, i.relPath, i.dirPath, i.size, NULL AS driveRelPath
        FROM assets a JOIN instances i ON i.hash = a.hash
        WHERE a.isLivePairedVideo = 0
        """

    // Drive-only branch: one row per asset that has NO local instance.
    // Deduped to one drive row per asset via MIN(rowid) when the asset is present on multiple drives.
    private static let driveSelect = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, a.rotation, vp.vaultID, vp.relPath, vp.dirPath, vp.size, vp.driveRelPath
        FROM assets a JOIN vault_presence vp ON vp.hash = a.hash
        WHERE a.isLivePairedVideo = 0
          AND NOT EXISTS (SELECT 1 FROM instances i WHERE i.hash = a.hash)
          AND vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.hash = a.hash)
        """

    // Full union: local rows (with NULL driveRelPath) UNION ALL drive-only rows.
    // Internal so that Catalog+Search.swift can reuse the union for filter/fetch queries.

    /// Per-INSTANCE rows (one per file) — the same photo in two folders appears twice. Used by the
    /// Folders views and instance resolution, where each physical file is its own row.
    static var instanceSQL: String { "\(localSelect) UNION ALL \(driveSelect)" }

    /// Deduped by CONTENT (one row per asset hash). The local branch keeps a single representative
    /// instance (lowest rowid); the drive-only branch already dedupes via MIN(rowid). Timeline + Search
    /// use this so a photo present in multiple folders shows once (its other locations live in the
    /// Inspector). `instanceSQL` and `browseSQL` differ ONLY in the local-branch dedupe clause.
    static var browseSQL: String {
        "\(localSelect) AND i.rowid = (SELECT MIN(rowid) FROM instances i2 WHERE i2.hash = a.hash)"
            + " UNION ALL \(driveSelect)"
    }

    /// Whole-library browse rows, newest first. `videoOnly` restricts to videos.
    public func timelineItems(videoOnly: Bool = false) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM (\(Self.browseSQL))"
            if videoOnly { sql += " WHERE kind = 'video'" }
            sql += " ORDER BY takenAtMs DESC"
            return try TimelineItem.fetchAll(db, sql: sql)
        }
    }

    /// `"<byteSize>|<captureSecond>"` fingerprints for every catalogued asset (local instances ∪
    /// drive-only). Lets the import grid flag a device photo that already exists anywhere in OpenPhoto
    /// — before it's downloaded, so without hashing the device file — using the same size + capture-
    /// second match the import registry and send-verifier use (`PresenceFingerprint.looselyMatches`).
    public func knownSizeDateKeys() throws -> Set<String> {
        try dbQueue.read { db in
            var keys = Set<String>()
            for row in try Row.fetchAll(db, sql: "SELECT size, takenAtMs FROM (\(Self.browseSQL))") {
                let size: Int64 = row["size"]; let ms: Int64 = row["takenAtMs"]
                keys.insert("\(size)|\(ms / 1000)")
            }
            return keys
        }
    }

    /// Items whose instance lives in the given folder.
    /// - Parameters:
    ///   - vaultID: when non-nil, restricts to that vault; nil = union across vaults.
    ///   - recursive: when true, also includes every descendant folder (the whole subtree).
    public func items(inDir dirPath: String, vaultID: String? = nil,
                      recursive: Bool = false) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM (\(Self.instanceSQL)) WHERE "
            var args: [DatabaseValueConvertible] = []
            if recursive {
                // The folder itself plus every descendant. GLOB "<dir>/*" matches only paths under
                // "<dir>/" (so a sibling like "2025x" is NOT matched), and isn't tripped by "_"/"%"
                // the way LIKE would be.
                sql += "(dirPath = ? OR dirPath GLOB ?)"
                args.append(dirPath)
                args.append(dirPath + "/*")
            } else {
                sql += "dirPath = ?"
                args.append(dirPath)
            }
            if let vid = vaultID {
                sql += " AND vaultID = ?"
                args.append(vid)
            }
            sql += " ORDER BY takenAtMs DESC"
            return try TimelineItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Resolve grid instanceIDs ("<vaultID>|<relPath>") back to browse rows — local
    /// instances and drive-only presence rows alike. Order is not preserved.
    public func items(instanceIDs: [String]) throws -> [TimelineItem] {
        guard !instanceIDs.isEmpty else { return [] }
        return try dbQueue.read { db in
            let marks = databaseQuestionMarks(count: instanceIDs.count)
            return try TimelineItem.fetchAll(db, sql: """
                SELECT * FROM (\(Self.instanceSQL)) WHERE vaultID || '|' || relPath IN (\(marks))
                """, arguments: StatementArguments(instanceIDs))
        }
    }

    /// dirPath → item count (local instances + drive-only assets, Mac-folder-aligned).
    /// - Parameter vaultID: when non-nil, restricts to that local vault; drive-only branch is
    ///   only included when vaultID is nil (drive-only assets have no local vaultID).
    public func folderCounts(vaultID: String? = nil, videoOnly: Bool = false) throws -> [String: Int] {
        try dbQueue.read { db in
            // Local branch
            var counts: [String: Int] = [:]
            let vf = videoOnly ? " AND a.kind = 'video'" : ""   // match the Folders grid's videos-only filter
            var sql = """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0\(vf)
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
                    WHERE a.isLivePairedVideo = 0\(vf)
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
                sql: "SELECT * FROM (\(Self.browseSQL)) WHERE hash = ? LIMIT 1",
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

    /// Mirror the sidecar's display rotation (0/90/180/270 CW) into the catalog for fast display.
    public func setRotation(hash: String, rotation: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET rotation = ? WHERE hash = ?",
                           arguments: [((rotation % 360) + 360) % 360, hash])
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

    public enum DuplicateScope: Sendable { case withinFolder, anywhere }

    /// Exact-content duplicate groups: instanceIDs ("vaultID|relPath") of files sharing the same
    /// content hash, in groups of 2+. `withinFolder` requires the same dirPath (truly redundant
    /// copies, safe to bin extras); `anywhere` groups the same content across folders.
    public func duplicateInstanceGroups(scope: DuplicateScope) throws -> [[String]] {
        struct GroupKey: Hashable { let hash: String; let dir: String }
        return try dbQueue.read { db in
            let dupFilter = scope == .withinFolder
                ? "(hash, dirPath) IN (SELECT hash, dirPath FROM instances GROUP BY hash, dirPath HAVING COUNT(*) >= 2)"
                : "hash IN (SELECT hash FROM instances GROUP BY hash HAVING COUNT(*) >= 2)"
            let rows = try Row.fetchAll(db, sql: """
                SELECT vaultID, relPath, hash, dirPath FROM instances
                WHERE \(dupFilter)
                ORDER BY hash, dirPath, rowid
                """)
            var groups: [GroupKey: [String]] = [:]
            for r in rows {
                let vaultID: String = r["vaultID"], relPath: String = r["relPath"]
                let hash: String = r["hash"], dirPath: String = r["dirPath"]
                let key = GroupKey(hash: hash, dir: scope == .withinFolder ? dirPath : "")
                groups[key, default: []].append("\(vaultID)|\(relPath)")
            }
            return groups.values.filter { $0.count >= 2 }.sorted { ($0.first ?? "") < ($1.first ?? "") }
        }
    }

    /// Every catalogued asset hash — the zero-I/O pre-flag for foreign-drive imports
    /// ("already in your library" from their manifest hashes, before any byte copies).
    public func assetHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT hash FROM assets"))
        }
    }

    /// Media OpenPhoto indexes on this Mac: file count + summed bytes (local instances). This is
    /// OpenPhoto's footprint, NOT the root folder's size — that folder also holds Photos libraries,
    /// app bundles, and other files OpenPhoto skips.
    public func librarySize() throws -> (count: Int, bytes: Int64) {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql:
                "SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM instances")
            return (row?["n"] ?? 0, row?["b"] ?? 0)
        }
    }
}
