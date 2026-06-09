import Foundation
import GRDB

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

    /// Full swap of a vault's presence set (mirrors `replaceInstances`).
    public func replaceVaultPresence(vaultID: String, hashes: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [vaultID])
            for h in hashes {
                try db.execute(sql: "INSERT OR IGNORE INTO vault_presence (vaultID, hash) VALUES (?, ?)",
                               arguments: [vaultID, h])
            }
        }
    }

    public func vaultPresenceHashes(forVault vaultID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT hash FROM vault_presence WHERE vaultID = ?", arguments: [vaultID]))
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
