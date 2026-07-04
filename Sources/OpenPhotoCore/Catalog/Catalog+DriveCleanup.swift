import Foundation
import GRDB

/// Catalog queries backing the proven-safe redundant-folder cleanup (and, later, reconcile-by-state).
/// The theme: locate *candidate surviving copies* of a hash so the caller can physically re-verify
/// them, and drop presence rows BY EXACT PATH so a shared hash's other placements are never touched.
extension Catalog {
    /// Local relPaths holding `hash` in one (local) vault — candidate survivors on the Mac to verify
    /// by re-hashing the actual file.
    public func instanceRelPaths(vaultID: String, hash: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT relPath FROM instances WHERE vaultID = ? AND hash = ?",
                arguments: [vaultID, hash])
        }
    }

    /// Drive paths holding `hash` on one vault — candidate same-drive survivors to verify by re-hashing.
    public func vaultPresenceDriveRelPaths(vaultID: String, hash: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db,
                sql: "SELECT driveRelPath FROM vault_presence WHERE vaultID = ? AND hash = ?",
                arguments: [vaultID, hash])
        }
    }

    /// Drop presence rows by EXACT drive path — never by hash. Removing one folder's mirror must leave
    /// a shared hash's surviving placements (e.g. the same photo filed elsewhere on the drive) intact;
    /// the by-hash `removeVaultPresence(hashes:)` would erase those too. Chunked under SQLite's variable
    /// limit.
    public func removeVaultPresence(vaultID: String, driveRelPaths: [String]) throws {
        guard !driveRelPaths.isEmpty else { return }
        try dbQueue.write { db in
            var i = 0
            while i < driveRelPaths.count {
                let chunk = Array(driveRelPaths[i..<min(i + 500, driveRelPaths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                try db.execute(
                    sql: "DELETE FROM vault_presence WHERE vaultID = ? AND driveRelPath IN (\(marks))",
                    arguments: StatementArguments([vaultID] + chunk))
                i += 500
            }
        }
    }
}
