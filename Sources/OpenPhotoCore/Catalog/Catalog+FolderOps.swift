import Foundation
import GRDB

public struct PendingFolderOp: Sendable, Equatable {
    public let id: Int64
    public let vaultID: String
    public let op: String          // "move" | "create" | "delete"
    public let src: String?
    public let dst: String?
    public let createdAtMs: Int64
}

extension Catalog {
    /// Record a structural folder op to apply to `vaultID` (an offline drive) on its next connect.
    @discardableResult
    public func enqueueFolderOp(vaultID: String, op: String, src: String?, dst: String?) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_folder_ops (vaultID, op, srcRelPath, dstRelPath, createdAtMs)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [vaultID, op, src, dst, now])
            return db.lastInsertedRowID
        }
    }

    /// Queued ops for a drive, oldest-first (apply in order).
    public func pendingFolderOps(forVault vaultID: String) throws -> [PendingFolderOp] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, vaultID, op, srcRelPath, dstRelPath, createdAtMs
                FROM pending_folder_ops WHERE vaultID = ? ORDER BY id
                """, arguments: [vaultID]).map { r in
                PendingFolderOp(id: r["id"], vaultID: r["vaultID"], op: r["op"],
                                src: r["srcRelPath"], dst: r["dstRelPath"], createdAtMs: r["createdAtMs"])
            }
        }
    }

    public func clearFolderOp(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_folder_ops WHERE id = ?", arguments: [id])
        }
    }

    public func clearFolderOps(forVault vaultID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_folder_ops WHERE vaultID = ?", arguments: [vaultID])
        }
    }
}
