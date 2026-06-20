import Foundation
import GRDB

/// A cached mirror of one entry in a drive's manifest, widened with path + size data.
/// Stored in `vault_presence` (rebuildable cache; dropping on migration is safe).
public struct VaultPresenceEntry: Sendable, Equatable {
    public let hash: String
    public let relPath: String      // Mac-aligned (for folder grouping/display)
    public let dirPath: String      // Mac-aligned dirname
    public let size: Int64
    public let driveRelPath: String // raw path on the drive (for reading full-res)
    public init(hash: String, relPath: String, dirPath: String, size: Int64, driveRelPath: String) {
        self.hash = hash; self.relPath = relPath; self.dirPath = dirPath
        self.size = size; self.driveRelPath = driveRelPath
    }
}

public final class Catalog: Sendable {
    public let dbQueue: DatabaseQueue

    /// On-disk catalog schema version — the latest registered migration below. Written into a
    /// drive's `catalog-snapshot/snapshot.json` (`catalog_schema_version`) and documented in
    /// `docs/format/catalog-schema.md`; bump in lockstep whenever a migration adds/changes tables.
    public static let schemaVersion = 13

    // MARK: Locked-folder state (in-memory; Touch ID resets on quit — visibility only, not encryption)
    // `fileprivate` so the `extension Catalog` in Queries.swift can read/write through the lock.
    let lockedLock = NSLock()
    // `nonisolated(unsafe)` because all access is guarded by `lockedLock` above.
    nonisolated(unsafe) var _revealLocked = false

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .text)
                t.column("role", .text).notNull()
                t.column("rootPath", .text).notNull()
                t.column("lastSeenMs", .integer).notNull()
            }
            try db.create(table: "assets") { t in
                t.primaryKey("hash", .text)
                t.column("kind", .text).notNull()
                t.column("takenAtMs", .integer).notNull().indexed()
                t.column("pixelWidth", .integer)
                t.column("pixelHeight", .integer)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("cameraModel", .text)
                t.column("lensModel", .text)
                t.column("durationSeconds", .double)
                t.column("livePairHash", .text)
                t.column("isLivePairedVideo", .boolean).notNull().defaults(to: false)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("caption", .text)
                t.column("tagsJSON", .text).notNull().defaults(to: "[]")
            }
            // No FK instances.hash → assets.hash: scan reconciliation may write instances first;
            // the catalog is rebuildable from vault files, so orphans are repaired by rescan.
            try db.create(table: "instances") { t in
                t.column("hash", .text).notNull().indexed()
                t.column("vaultID", .text).notNull()
                t.column("relPath", .text).notNull()
                t.column("dirPath", .text).notNull().indexed()
                t.column("size", .integer).notNull()
                t.column("mtimeMs", .integer).notNull()
                t.primaryKey(["vaultID", "relPath"])
            }
        }
        migrator.registerMigration("v2") { db in
            // Presence of an asset hash in a NON-local vault (a drive), derived from
            // that vault's manifest. Local-vault presence already lives in `instances`.
            try db.create(table: "vault_presence") { t in
                t.column("vaultID", .text).notNull()
                t.column("hash", .text).notNull().indexed()
                t.primaryKey(["vaultID", "hash"])
            }
        }
        migrator.registerMigration("v3") { db in
            // vault_presence is a rebuildable cache — drop and recreate widened with
            // path/size data so browse queries can show drive-only assets in folders.
            try db.execute(sql: "DROP TABLE IF EXISTS vault_presence")
            try db.create(table: "vault_presence") { t in
                t.column("vaultID", .text).notNull()
                t.column("hash", .text).notNull().indexed()
                t.column("relPath", .text).notNull()
                t.column("dirPath", .text).notNull().indexed()
                t.column("size", .integer).notNull()
                t.column("driveRelPath", .text).notNull()
                t.primaryKey(["vaultID", "hash"])
            }
        }
        migrator.registerMigration("v4") { db in
            // Delete-only propagation queue (rebuildable cache). Evict never writes here.
            try db.create(table: "pending_deletions") { t in
                t.primaryKey("hash", .text)
                t.column("relPath", .text).notNull()
                t.column("deletedAtMs", .integer).notNull()
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-asset per-stage derivation completion (rebuildable cache; resumable, retry-capped).
            try db.create(table: "derivation_jobs") { t in
                t.column("hash", .text).notNull()
                t.column("stage", .text).notNull()
                t.column("status", .text).notNull()        // "done" | "failed"
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("updatedAtMs", .integer).notNull()
                t.primaryKey(["hash", "stage"])
            }
            // Full-text index over recognized text (rebuildable cache).
            try db.create(virtualTable: "ocr", using: FTS5()) { t in
                t.column("hash").notIndexed()
                t.column("text")
            }
        }
        migrator.registerMigration("v6") { db in
            // Structural folder ops queued for an offline durable drive — applied on reconnect
            // before sync so the path-keyed sync doesn't duplicate files.
            try db.create(table: "pending_folder_ops") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("vaultID", .text).notNull()
                t.column("op", .text).notNull()          // "move" | "create" | "delete"
                t.column("srcRelPath", .text)
                t.column("dstRelPath", .text)
                t.column("createdAtMs", .integer).notNull()
            }
        }
        migrator.registerMigration("v7") { db in
            // Per-asset CLIP-class image embedding (rebuildable cache; machine-derived).
            // `vector` = dim × Float16 little-endian, L2-normalized. `model` lets a swap invalidate.
            try db.create(table: "embeddings") { t in
                t.primaryKey("hash", .text)
                t.column("model", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
        }
        migrator.registerMigration("v8") { db in
            // Detected faces (rebuildable cache; machine-derived) + named people. `personID`/the
            // people `name` MIRROR human decisions recorded as MWG regions in XMP sidecars; the
            // sidecars are authoritative and reconstitute confirmed rows on rebuild.
            try db.create(table: "people") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(table: "faces") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("hash", .text).notNull().indexed()      // → assets.hash
                t.column("rectX", .double).notNull()             // Vision normalized boundingBox
                t.column("rectY", .double).notNull()
                t.column("rectW", .double).notNull()
                t.column("rectH", .double).notNull()
                t.column("embedding", .blob).notNull()           // dim × Float16 LE feature-print
                t.column("dim", .integer).notNull()
                t.column("personID", .integer).indexed()         // NULL = unassigned
                t.column("confidence", .double).notNull()
                t.column("source", .text).notNull()              // "auto" | "confirmed"
            }
        }
        migrator.registerMigration("v9") { db in
            // Reverse-geocoded place per geotagged asset (rebuildable cache; 100% machine-derived —
            // a deterministic function of assets.latitude/longitude + the bundled GeoNames dataset).
            // Catalog-only: NO sidecar, NO format change. Dropping it re-derives from lat/lon.
            try db.create(table: "geocode") { t in
                t.primaryKey("hash", .text)              // → assets.hash
                t.column("city", .text)
                t.column("region", .text)
                t.column("country", .text)
                t.column("countryCode", .text).indexed()
            }
            try db.create(index: "idx_geocode_city", on: "geocode", columns: ["city"])
        }
        migrator.registerMigration("v10") { db in
            // Perceptual image hash (dHash) per photo — rebuildable cache, 100% machine-derived
            // (a deterministic function of the image bytes). Catalog-only: NO sidecar, NO format
            // change. Dropping it re-derives by re-running PHashStage.
            try db.create(table: "phash") { t in
                t.primaryKey("hash", .text)            // → assets.hash
                t.column("value", .integer).notNull()  // 64-bit dHash, stored as signed Int64
            }
        }
        migrator.registerMigration("v11") { db in
            // Per-photo last-synced tag set — the 3-way-merge baseline for Finder-tag sync. Rebuildable
            // sync-state, machine-derived. Catalog-only: NO sidecar, NO format change. Dropping it makes
            // the next sync additive for one cycle, then re-seeds.
            try db.create(table: "finder_tag_sync") { t in
                t.primaryKey("hash", .text)             // → assets.hash
                t.column("baseline", .text).notNull()   // JSON array of tag strings
            }
        }
        migrator.registerMigration("v12") { db in
            // User-chosen cover face for the People screen — a Mac-local display preference. Nullable:
            // when NULL (or when the stored faceID no longer belongs to this person), people() falls back
            // to the highest-confidence face via COALESCE. Stale values are never cleaned up eagerly.
            try db.alter(table: "people") { t in
                t.add(column: "coverFaceID", .integer)  // → faces.id; nullable
            }
        }
        migrator.registerMigration("v13") { db in
            // Display rotation (0/90/180/270, clockwise), human-chosen, mirrored from the XMP sidecar's
            // tiff:Orientation. Display-only — original pixels are never modified (format spec §3/§9).
            try db.alter(table: "assets") { t in
                t.add(column: "rotation", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v14") { db in
            // Face-recognition v2 (AdaFace IR-101). Two rebuildable, machine-derived additions —
            // catalog-only, NO sidecar, NO on-disk format change:
            //  • faces.quality — clusterability score (capture quality if the face passed the quality
            //    gate, else 0). The clusterer reads only quality>0 faces; gated faces remain for
            //    display + manual assignment. Existing rows default to 1 (re-derived by the rescan).
            //  • catalog_meta — a tiny key/value store; holds `faceModelVersion` so a model change
            //    triggers a one-time face re-derivation (old dim≠512 vectors self-exclude regardless).
            try db.alter(table: "faces") { t in
                t.add(column: "quality", .double).notNull().defaults(to: 1)
            }
            try db.create(table: "catalog_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v15") { db in
            // User-hidden faces: a reversible "ignore" for the Other-faces bucket. Hidden auto faces
            // are pulled from the bucket and excluded from suggestions, but never deleted — a
            // "Show hidden" toggle restores them. Catalog-only (rebuildable); a full face
            // re-derivation (Rescan Faces) resets it.
            try db.alter(table: "faces") { t in
                t.add(column: "hidden", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v16") { db in
            // Per-instance "locked" flag for app-level Touch-ID-hidden folders. Derived (rebuildable)
            // from the locked-folder list; gates browse VISIBILITY only — it is NOT encryption.
            try db.alter(table: "instances") { t in
                t.add(column: "locked", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v17") { db in
            // Per-(person, face) "not this person" dismissals from the suggestion strip's ✕ — suppresses
            // re-suggesting a face to a group the user rejected it for (a face can still be suggested for
            // OTHER people). Catalog-only (rebuildable), NO sidecar / NO on-disk format change: a full
            // face re-derivation (Rescan Faces) changes faceIDs, so it's cleared there.
            try db.create(table: "dismissed_suggestions") { t in
                t.column("personID", .integer).notNull()
                t.column("faceID", .integer).notNull()
                t.primaryKey(["personID", "faceID"])
            }
        }
        migrator.registerMigration("v18") { db in
            // Albums mirror (rebuildable from the sovereign `.openphoto/albums/*.json` files).
            // Members are content hashes with an explicit order; lock-gating reuses the same
            // instance visibility rules as the rest of browse.
            try db.create(table: "albums") { t in
                t.primaryKey("id", .text)            // UUID == album file stem
                t.column("name", .text).notNull()
                t.column("coverHash", .text)
                t.column("createdAtMs", .integer).notNull()
                t.column("modifiedAtMs", .integer).notNull()
            }
            try db.create(table: "album_members") { t in
                t.column("albumID", .text).notNull()
                t.column("hash", .text).notNull().indexed()
                t.column("position", .integer).notNull()
                t.primaryKey(["albumID", "hash"])
            }
        }
        migrator.registerMigration("v19") { db in
            // 2D positions for the Face Map (rebuildable local cache; NOT part of the sovereign
            // drive snapshot — schemaVersion intentionally not bumped). Recomputed whenever the
            // face set changes; see Catalog.faceSetFingerprint / catalog_meta "faceLayoutFingerprint".
            try db.create(table: "face_layout") { t in
                t.primaryKey("faceID", .integer)        // → faces.id
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("layoutVersion", .integer).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func registerVault(id: String, role: String, rootPath: String) throws {
        try dbQueue.write { db in
            try VaultRecord(id: id, role: role, rootPath: rootPath,
                            lastSeenMs: Int64(Date().timeIntervalSince1970 * 1000)).save(db)
        }
    }

    public func registeredVaults() throws -> [VaultRecord] {
        try dbQueue.read { db in try VaultRecord.fetchAll(db) }
    }

    public func setVaultLastSeen(id: String, ms: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE vaults SET lastSeenMs = ? WHERE id = ?", arguments: [ms, id])
        }
    }

    /// Atomically designate `newID` the canonical and (if given) demote `oldID` to backup — one
    /// transaction, so the catalog never momentarily has zero or two canonicals. The drives'
    /// `vault.json` self-descriptions are reconciled separately (best-effort); the catalog role is
    /// authoritative for "which drive is THE canonical".
    public func setCanonical(_ newID: String, demoting oldID: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE vaults SET role = 'canonical' WHERE id = ?", arguments: [newID])
            if let oldID {
                try db.execute(sql: "UPDATE vaults SET role = 'backup' WHERE id = ?", arguments: [oldID])
            }
        }
    }

    /// Forget a vault: drop its registration + its presence rows. Files on disk are untouched;
    /// the catalog is rebuildable, so any drive-only AssetRecords it left become harmless orphans.
    public func unregisterVault(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vaults WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [id])
        }
    }

    /// Remove a *local* vault entirely: its instances, its registration/presence, and any per-hash
    /// derived rows left with no backing instance AND no drive presence. Drive-only assets (tracked
    /// via another vault's `vault_presence`) are preserved. Files on disk are untouched; everything
    /// removed here is rebuildable by rescanning the folder. Used by "switch library".
    public func purgeLocalVault(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM instances WHERE vaultID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vaults WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [id])
            let orphan = """
                hash NOT IN (SELECT hash FROM instances)
                AND hash NOT IN (SELECT hash FROM vault_presence)
                """
            for table in ["assets", "faces", "embeddings", "phash", "geocode",
                          "derivation_jobs", "finder_tag_sync", "ocr", "pending_deletions"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE \(orphan)")
            }
        }
    }

    /// Full swap of a vault's presence set — stores path/size data alongside the hash
    /// so browse queries can surface drive-only assets in folder views.
    public func replaceVaultPresence(vaultID: String, entries: [VaultPresenceEntry]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [vaultID])
            for e in entries {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO vault_presence (vaultID, hash, relPath, dirPath, size, driveRelPath)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [vaultID, e.hash, e.relPath, e.dirPath, e.size, e.driveRelPath])
            }
        }
    }

    /// Read all presence entries for a vault (for browse queries that need path data).
    public func vaultPresenceRows(forVault vaultID: String) throws -> [VaultPresenceEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, relPath, dirPath, size, driveRelPath FROM vault_presence WHERE vaultID = ?
                """, arguments: [vaultID]).map {
                VaultPresenceEntry(hash: $0["hash"], relPath: $0["relPath"], dirPath: $0["dirPath"],
                                   size: $0["size"], driveRelPath: $0["driveRelPath"])
            }
        }
    }

    public func vaultPresenceHashes(forVault vaultID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT hash FROM vault_presence WHERE vaultID = ?", arguments: [vaultID]))
        }
    }

    // MARK: Pending deletions (Slice 3 — Delete-only queue)

    public func enqueuePendingDeletion(hash: String, relPath: String, deletedAtMs: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_deletions (hash, relPath, deletedAtMs) VALUES (?, ?, ?)
                ON CONFLICT(hash) DO UPDATE SET relPath = excluded.relPath,
                                                deletedAtMs = excluded.deletedAtMs
                """, arguments: [hash, relPath, deletedAtMs])
        }
    }

    public func dequeuePendingDeletion(hash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_deletions WHERE hash = ?", arguments: [hash])
        }
    }

    public func clearPendingDeletions(hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: "DELETE FROM pending_deletions WHERE hash IN (\(marks))",
                           arguments: StatementArguments(hashes))
        }
    }

    /// Clear a pending deletion only once NO vault still holds the hash in presence — i.e. it has
    /// been binned on every copy. A drive that still holds it (e.g. a disconnected backup whose
    /// presence row persists) keeps the deletion pending until it too is propagated.
    public func clearPendingDeletionsWithoutPresence(hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: """
                DELETE FROM pending_deletions
                WHERE hash IN (\(marks))
                  AND NOT EXISTS (SELECT 1 FROM vault_presence vp WHERE vp.hash = pending_deletions.hash)
                """, arguments: StatementArguments(hashes))
        }
    }

    public func pendingDeletions() throws -> [PendingDeletionRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, relPath, deletedAtMs FROM pending_deletions ORDER BY deletedAtMs DESC
                """).map {
                PendingDeletionRecord(hash: $0["hash"], relPath: $0["relPath"],
                                      deletedAtMs: $0["deletedAtMs"])
            }
        }
    }

    // MARK: Eligibility-support accessors (Slice 3 — Task 2)

    /// Distinct hashes that have a LOCAL instance (drive presence lives in vault_presence,
    /// never in `instances`). Used by deletion eligibility's "no local copy remains" rule.
    public func instanceHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT hash FROM instances"))
        }
    }

    /// The paired-video hash for a Live Photo still (nil otherwise) — lets restore mirror
    /// the dequeue onto the pair.
    public func assetLivePairHash(forHash hash: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT livePairHash FROM assets WHERE hash = ?",
                                arguments: [hash])
        }
    }

    /// Drop specific hashes from one vault's presence mirror (after they're propagated off it).
    public func removeVaultPresence(vaultID: String, hashes: [String]) throws {
        guard !hashes.isEmpty else { return }
        try dbQueue.write { db in
            let marks = databaseQuestionMarks(count: hashes.count)
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ? AND hash IN (\(marks))",
                           arguments: StatementArguments([vaultID] + hashes))
        }
    }

    /// Re-key cached drive presence after a Mac folder move (`fromDir` → `toDir`, both Mac-aligned
    /// dir paths). Every `vault_presence` row whose Mac-aligned path sits under `fromDir/` has its
    /// `relPath`, `dirPath`, and (basename-prefixed) `driveRelPath` rewritten onto the new location —
    /// across EVERY drive, connected or not. Without this, drive-only originals (kept on a drive,
    /// freed from the Mac) keep counting under the old `dirPath` and the moved folder lingers as a
    /// phantom in `folderCounts` (re-dragging it then fails because the directory is gone on disk).
    /// Pure catalog op (no disk access); the on-disk mirror of this is `VaultReorganizer`'s manifest
    /// prefix-rewrite, applied to the connected drive during the same move.
    public func rewriteVaultPresencePaths(fromDir: String, toDir: String) throws {
        let from = fromDir.precomposedStringWithCanonicalMapping
        let to = toDir.precomposedStringWithCanonicalMapping
        guard !from.isEmpty, from != to else { return }
        try dbQueue.write { db in
            // GLOB '<from>/*' matches any depth (SQLite GLOB '*' spans '/'), same idiom as
            // items(inDir:recursive:). The Swift-side hasPrefix guard keeps it exact.
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS rid, relPath, driveRelPath FROM vault_presence WHERE relPath GLOB ?
                """, arguments: [from + "/*"])
            for row in rows {
                let rid: Int64 = row["rid"]
                let oldRel: String = row["relPath"]
                let oldDriveRel: String = row["driveRelPath"]
                guard oldRel.hasPrefix(from + "/") else { continue }
                let newRel = to + oldRel.dropFirst(from.count)
                let newDir = (newRel as NSString).deletingLastPathComponent
                // driveRelPath = <optional drive basename> + "/" + <Mac relPath>; the Mac relPath is
                // always a suffix, so swap only that suffix (handles prefixed + unprefixed shapes).
                let newDriveRel = oldDriveRel.hasSuffix(oldRel)
                    ? String(oldDriveRel.dropLast(oldRel.count)) + newRel
                    : oldDriveRel
                try db.execute(sql: """
                    UPDATE vault_presence SET relPath = ?, dirPath = ?, driveRelPath = ? WHERE rowid = ?
                    """, arguments: [newRel, newDir, newDriveRel, rid])
            }
        }
    }

    /// The presence-row relPath for one asset on one drive — Live-pair partner
    /// resolution for drive-only moves. Nil when the drive has no row for the hash.
    public func vaultPresenceRelPath(vaultID: String, hash: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT relPath FROM vault_presence WHERE vaultID = ? AND hash = ? LIMIT 1
                """, arguments: [vaultID, hash])
        }
    }

    /// File-grain sibling of `rewriteVaultPresencePaths`: re-key ONE drive's presence row
    /// after a per-photo move (`fromRelPath` → `toRelPath`, both Mac-aligned). Pure catalog
    /// op; the drive's file is moved now (connected) or queued (offline) by the caller.
    public func rewriteVaultPresencePath(vaultID: String, fromRelPath: String,
                                         toRelPath: String) throws {
        let from = fromRelPath.precomposedStringWithCanonicalMapping
        let to = toRelPath.precomposedStringWithCanonicalMapping
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS rid, driveRelPath FROM vault_presence
                WHERE vaultID = ? AND relPath = ?
                """, arguments: [vaultID, from])
            for row in rows {
                let rid: Int64 = row["rid"]
                let oldDriveRel: String = row["driveRelPath"]
                // Same suffix-swap as the dir-grain rewrite (prefixed + unprefixed shapes).
                let newDriveRel = oldDriveRel.hasSuffix(from)
                    ? String(oldDriveRel.dropLast(from.count)) + to
                    : oldDriveRel
                try db.execute(sql: """
                    UPDATE vault_presence SET relPath = ?, dirPath = ?, driveRelPath = ?
                    WHERE rowid = ?
                    """, arguments: [to, (to as NSString).deletingLastPathComponent,
                                     newDriveRel, rid])
            }
        }
    }

    public func upsert(assets: [AssetRecord]) throws {
        try dbQueue.write { db in for a in assets { try a.upsert(db) } }
    }

    /// Insert assets that don't already exist; never overwrite an existing row (so a snapshot
    /// import can't clobber the Mac's authoritative human metadata).
    public func insertAssetsIfAbsent(_ assets: [AssetRecord]) throws {
        try dbQueue.write { db in
            for a in assets { try a.insert(db, onConflict: .ignore) }
        }
    }

    public func upsert(instances: [InstanceRecord]) throws {
        try dbQueue.write { db in for i in instances { try i.upsert(db) } }
    }

    /// Wholesale replacement of a vault's instances (scan reconcile).
    public func replaceInstances(inVault vaultID: String, with instances: [InstanceRecord]) throws {
        try dbQueue.write { db in
            // Preserve the per-folder `locked` flag across this wholesale replace. `InstanceRecord`
            // doesn't model `locked`, so a plain DELETE+re-insert resets it to the column default (0)
            // — which silently defeated the locked-folder gate (browse hides rows WHERE locked=0)
            // on EVERY scan, exposing locked folders in the grid, timeline, faces and search until a
            // manual lock/unlock re-applied it. Capture the locked folders first, then re-mark them
            // (recursively) after re-insert, so a scan can no longer leak locked content.
            let lockedDirs = try String.fetchAll(db, sql:
                "SELECT DISTINCT dirPath FROM instances WHERE vaultID = ? AND locked = 1",
                arguments: [vaultID])
            try db.execute(sql: "DELETE FROM instances WHERE vaultID = ?", arguments: [vaultID])
            for i in instances { try i.upsert(db) }
            for dir in lockedDirs {
                try db.execute(sql: """
                    UPDATE instances SET locked = 1
                    WHERE vaultID = ? AND (dirPath = ? OR dirPath GLOB ?)
                    """, arguments: [vaultID, dir, dir + "/*"])
            }
        }
    }

    public func assetCount() throws -> Int {
        try dbQueue.read { db in try AssetRecord.fetchCount(db) }
    }

    public func knownHashes() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT hash FROM assets"))
        }
    }
}
