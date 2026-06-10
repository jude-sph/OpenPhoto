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

    /// Forget a vault: drop its registration + its presence rows. Files on disk are untouched;
    /// the catalog is rebuildable, so any drive-only AssetRecords it left become harmless orphans.
    public func unregisterVault(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vaults WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [id])
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

    public func upsert(assets: [AssetRecord]) throws {
        try dbQueue.write { db in for a in assets { try a.upsert(db) } }
    }

    public func upsert(instances: [InstanceRecord]) throws {
        try dbQueue.write { db in for i in instances { try i.upsert(db) } }
    }

    /// Wholesale replacement of a vault's instances (scan reconcile).
    public func replaceInstances(inVault vaultID: String, with instances: [InstanceRecord]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM instances WHERE vaultID = ?", arguments: [vaultID])
            for i in instances { try i.upsert(db) }
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
