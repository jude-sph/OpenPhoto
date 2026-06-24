import Foundation
import GRDB

extension Catalog {
    // Local branch: one row per INSTANCE (asset present in a local vault).
    // Assets in two vaults appear twice — intentional v1; dedup review handles duplicates (phase 5).
    // Selects NULL for driveRelPath because local instances always have a reachable file.
    private static let localSelect = """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, a.rotation, i.vaultID, i.relPath, i.dirPath, i.size, i.locked, NULL AS driveRelPath
        FROM assets a JOIN instances i ON i.hash = a.hash
        WHERE a.isLivePairedVideo = 0
        """

    // Drive-only branch. Two flavours that differ ONLY in the "drive-only" test + the dedupe:
    //  - byLocation: one row per FOLDER LOCATION — surfaces when THIS path has no local instance,
    //    deduped across drives by relPath. The Folders views use it, so a photo in several folders
    //    shows in EVERY folder once its local copies are evicted (vault_presence is keyed per file).
    //  - byAsset: one row per HASH — surfaces when the photo has no local instance ANYWHERE, deduped
    //    to one. The Timeline/Search browse use it, so a photo appears once.
    private static func driveSelect(notExists: String, dedup: String) -> String { """
        SELECT a.hash, a.kind, a.takenAtMs, a.pixelWidth, a.pixelHeight, a.latitude, a.longitude,
               a.cameraModel, a.lensModel, a.durationSeconds, a.livePairHash, a.favorite, a.rating,
               a.caption, a.tagsJSON, a.rotation, vp.vaultID, vp.relPath, vp.dirPath, vp.size, 0 AS locked, vp.driveRelPath
        FROM assets a JOIN vault_presence vp ON vp.hash = a.hash
        WHERE a.isLivePairedVideo = 0
          AND NOT EXISTS (SELECT 1 FROM instances i WHERE i.hash = a.hash\(notExists))
          AND vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE \(dedup))
        """ }
    static var driveSelectByLocation: String {
        driveSelect(notExists: " AND i.relPath = vp.relPath", dedup: "v2.relPath = vp.relPath")
    }
    private static var driveSelectByAsset: String {
        driveSelect(notExists: "", dedup: "v2.hash = vp.hash")
    }

    // Full union: local rows (with NULL driveRelPath) UNION ALL drive-only rows.
    // Internal so that Catalog+Search.swift can reuse the union for filter/fetch queries.

    /// Per-INSTANCE rows (one per file/location) — the same photo in two folders appears twice. Used
    /// by the Folders views and instance resolution, where each physical location is its own row.
    static var instanceSQL: String { "\(localSelect) UNION ALL \(driveSelectByLocation)" }

    /// Deduped by CONTENT (one row per asset hash). The local branch keeps a single representative
    /// instance (lowest rowid); the drive-only branch dedupes by hash. Timeline + Search use this so a
    /// photo present in multiple folders shows once (its other locations live in the Inspector).
    static var browseSQL: String {
        "\(localSelect) AND i.rowid = (SELECT MIN(rowid) FROM instances i2 WHERE i2.hash = a.hash)"
            + " UNION ALL \(driveSelectByAsset)"
    }

    // MARK: Locked-folder visibility gate

    /// When false (default), user-facing browse methods hide locked rows. The App flips it true for
    /// the session after Touch ID. In-memory only — re-locks naturally on quit.
    /// This is visibility-gating, not encryption.
    public var revealLocked: Bool {
        get { lockedLock.withLock { _revealLocked } }
        set { lockedLock.withLock { _revealLocked = newValue } }
    }

    /// SQL fragment appended to user-facing browse queries; empty string when revealed.
    var lockedFilter: String { revealLocked ? "" : "AND locked = 0" }

    /// SQL clause keeping only rows whose hash is browse-visible (has a non-locked instance), unless
    /// the session is revealed. `hashColumn` is a code-controlled column ref like "f.hash" (not user input).
    /// Photos with NO instances at all (orphans / drive-only / test fixtures) are not filtered — they have
    /// never been placed in a locked folder, so the lock check is vacuously satisfied.
    func lockedVisibilityClause(hashColumn: String) -> String {
        revealLocked ? "" :
            "AND (NOT EXISTS (SELECT 1 FROM instances vi WHERE vi.hash = \(hashColumn))" +
            " OR EXISTS (SELECT 1 FROM instances vi WHERE vi.hash = \(hashColumn) AND vi.locked = 0))"
    }

    /// Re-derive `instances.locked` from the locked-folder list: clear all, then mark instances
    /// whose dirPath equals or is nested under a locked folder (same GLOB the Folders view uses).
    /// Rebuildable — re-calling with the same list is idempotent.
    public func applyLockedFolders(_ dirPaths: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE instances SET locked = 0")
            for p in dirPaths {
                try db.execute(sql: "UPDATE instances SET locked = 1 WHERE dirPath = ? OR dirPath GLOB ?",
                               arguments: [p, p + "/*"])
            }
        }
    }

    /// Whole-library browse rows, newest first. `videoOnly` restricts to videos.
    public func timelineItems(videoOnly: Bool = false) throws -> [TimelineItem] {
        try dbQueue.read { db in
            var conditions: [String] = []
            if videoOnly { conditions.append("kind = 'video'") }
            if !revealLocked { conditions.append("locked = 0") }
            let where_ = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            let sql = "SELECT * FROM (\(Self.browseSQL))\(where_) ORDER BY takenAtMs DESC"
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
            let lf = lockedFilter
            if !lf.isEmpty { sql += " \(lf)" }
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
            let lf = lockedFilter
            let lockClause = lf.isEmpty ? "" : " \(lf)"
            return try TimelineItem.fetchAll(db, sql: """
                SELECT * FROM (\(Self.instanceSQL)) WHERE vaultID || '|' || relPath IN (\(marks))\(lockClause)
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
            let lf = lockedFilter.isEmpty ? "" : " AND i.locked = 0"   // hide locked instances when not revealed
            var sql = """
                SELECT i.dirPath AS d, COUNT(*) AS n FROM instances i
                JOIN assets a ON a.hash = i.hash
                WHERE a.isLivePairedVideo = 0\(vf)\(lf)
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
            // Drive-only rows are never locked (v1), so no lock filter needed here.
            if vaultID == nil {
                let dsql = """
                    SELECT vp.dirPath AS d, COUNT(*) AS n FROM vault_presence vp
                    JOIN assets a ON a.hash = vp.hash
                    WHERE a.isLivePairedVideo = 0\(vf)
                      AND NOT EXISTS (SELECT 1 FROM instances i WHERE i.hash = vp.hash AND i.relPath = vp.relPath)
                      AND vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.relPath = vp.relPath)
                    GROUP BY vp.dirPath
                    """
                for r in try Row.fetchAll(db, sql: dsql) {
                    counts[r["d"], default: 0] += (r["n"] as Int)
                }
            }
            return counts
        }
    }

    /// Every local original (one row per `instances` row), built as a `TimelineItem` with
    /// `driveRelPath == nil`. This is the local branch of the browse union, undeduped — the same
    /// content in two folders yields two rows. Storage's evict-all gather filters this set.
    public func allLocalInstances() throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(db, sql: Self.localSelect)
        }
    }

    /// Every asset present on a drive but absent from the Mac (no local `instances` row), one row per
    /// asset (deduped via MIN(rowid) when on multiple drives), built with `driveRelPath` set. The exact
    /// drive-only branch the Folders view surfaces. Storage's rehydrate-all gather uses this set.
    public func allDriveOnlyItems() throws -> [TimelineItem] {
        try dbQueue.read { db in
            try TimelineItem.fetchAll(db, sql: Self.driveSelectByLocation)
        }
    }

    public func item(hash: String) throws -> TimelineItem? {
        try dbQueue.read { db in
            let lf = lockedFilter
            let lockClause = lf.isEmpty ? "" : " \(lf)"
            return try TimelineItem.fetchOne(db,
                sql: "SELECT * FROM (\(Self.browseSQL)) WHERE hash = ?\(lockClause) LIMIT 1",
                arguments: [hash])
        }
    }

    /// All local instances of an asset (across vaults) — internal use (sidecar writes,
    /// deletion, drive-copy resolution). Always returns every copy regardless of lock state.
    /// For user-facing "where this photo lives" display, use `visibleInstances(forHash:)`.
    public func instances(forHash hash: String) throws -> [InstanceRecord] {
        try dbQueue.read { db in
            try InstanceRecord.fetchAll(db, sql: "SELECT * FROM instances WHERE hash = ?",
                                        arguments: [hash])
        }
    }

    /// Local instances of an asset visible to the user — excludes locked-folder copies when
    /// `!revealLocked`. Used by the Inspector's "Also in N other folders" section.
    public func visibleInstances(forHash hash: String) throws -> [InstanceRecord] {
        let lf = lockedFilter   // "AND locked = 0" or ""
        return try dbQueue.read { db in
            let sql = "SELECT * FROM instances WHERE hash = ?\(lf.isEmpty ? "" : " AND locked = 0")"
            return try InstanceRecord.fetchAll(db, sql: sql, arguments: [hash])
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

    /// hash → durationSeconds for every asset that has one (i.e. videos). The scanner feeds these
    /// to `LivePhotoPairer` so its basename fallback can reject a video too long to be Live motion.
    public func videoDurations() throws -> [String: Double] {
        try dbQueue.read { db in
            var out: [String: Double] = [:]
            for r in try Row.fetchAll(db, sql:
                "SELECT hash, durationSeconds FROM assets WHERE durationSeconds IS NOT NULL") {
                out[r["hash"]] = r["durationSeconds"]
            }
            return out
        }
    }

    /// Self-heal mis-pairings: un-pair any video flagged as Live motion whose stored duration proves
    /// it can't be (longer than `maxSeconds`) — e.g. a 7-minute clip wrongly folded into a same-named
    /// photo before the duration guard existed. Clears both the video flag and the photo's pointer.
    /// Targeted by duration (not "not re-derived"), so a legitimately-paired short clip is untouched.
    @discardableResult
    public func unpairOverlongVideos(maxSeconds: Double) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET livePairHash = NULL
                WHERE livePairHash IN (SELECT hash FROM assets WHERE durationSeconds > ?)
                """, arguments: [maxSeconds])
            try db.execute(sql: """
                UPDATE assets SET isLivePairedVideo = 0
                WHERE isLivePairedVideo = 1 AND durationSeconds > ?
                """, arguments: [maxSeconds])
            return db.changesCount
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

    /// The display rotation (0/90/180/270 CW) stored for an asset, or 0 if unknown.
    public func rotation(forHash hash: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT rotation FROM assets WHERE hash = ?", arguments: [hash]) ?? 0
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
            let lf = lockedFilter.isEmpty ? "" : " AND locked = 0"
            let dupFilter = scope == .withinFolder
                ? "(hash, dirPath) IN (SELECT hash, dirPath FROM instances WHERE 1=1\(lf) GROUP BY hash, dirPath HAVING COUNT(*) >= 2)"
                : "hash IN (SELECT hash FROM instances WHERE 1=1\(lf) GROUP BY hash HAVING COUNT(*) >= 2)"
            let rows = try Row.fetchAll(db, sql: """
                SELECT vaultID, relPath, hash, dirPath FROM instances
                WHERE \(dupFilter)\(lf)
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
    /// app bundles, and other files OpenPhoto skips. Locked folders are excluded unless revealed.
    public func librarySize() throws -> (count: Int, bytes: Int64) {
        try dbQueue.read { db in
            let lf = lockedFilter.isEmpty ? "" : " WHERE locked = 0"
            let row = try Row.fetchOne(db, sql:
                "SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM instances\(lf)")
            return (row?["n"] ?? 0, row?["b"] ?? 0)
        }
    }
}
