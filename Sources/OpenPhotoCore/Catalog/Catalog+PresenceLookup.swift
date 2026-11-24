import Foundation
import GRDB

/// Point lookups into `vault_presence`. The table is indexed on `hash`, so these are sub-millisecond;
/// use them instead of loading a drive's WHOLE presence set (`vaultPresenceRows(forVault:)` /
/// `vaultPresenceHashes(forVault:)`) just to find one photo.
extension Catalog {

    /// The presence row for `hash` on one vault, or nil. (First row if the drive holds the content at
    /// several paths — same choice `vaultPresenceRows(forVault:).first(where:)` made.)
    public func presenceRow(vaultID: String, hash: String) throws -> VaultPresenceEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT hash, relPath, dirPath, size, driveRelPath FROM vault_presence
                WHERE hash = ? AND vaultID = ? ORDER BY rowid LIMIT 1
                """, arguments: [hash, vaultID]).map(Self.presenceEntry)
        }
    }

    /// Every presence row for `hash`, across all vaults, tagged with its vault.
    public func presenceRows(forHash hash: String) throws -> [(vaultID: String, entry: VaultPresenceEntry)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT vaultID, hash, relPath, dirPath, size, driveRelPath FROM vault_presence
                WHERE hash = ? ORDER BY rowid
                """, arguments: [hash]).map { (vaultID: $0["vaultID"], entry: Self.presenceEntry($0)) }
        }
    }

    /// IDs of the vaults whose presence set contains `hash`.
    public func vaultIDsHolding(hash: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT DISTINCT vaultID FROM vault_presence WHERE hash = ?", arguments: [hash]))
        }
    }

    /// True when the vault has at least one presence row (replaces loading the full set for `.isEmpty`).
    public func hasAnyPresence(vaultID: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM vault_presence WHERE vaultID = ?)", arguments: [vaultID]) ?? false
        }
    }

    /// Number of presence rows on a vault.
    public func presenceCount(vaultID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM vault_presence WHERE vaultID = ?", arguments: [vaultID]) ?? 0
        }
    }

    /// One vault's presence keyed by hash (first row per hash) — for batch loops that need many
    /// lookups against the same drive: load once, then O(1) per item.
    public func presenceRowsByHash(vaultID: String) throws -> [String: VaultPresenceEntry] {
        var out: [String: VaultPresenceEntry] = [:]
        for row in try vaultPresenceRows(forVault: vaultID) where out[row.hash] == nil { out[row.hash] = row }
        return out
    }

    /// Of `hashes`, those present on at least one of `vaultIDs` (chunked to stay under SQLite's
    /// bound-variable limit).
    public func hashesPresent(_ hashes: [String], onAnyOf vaultIDs: [String]) throws -> Set<String> {
        guard !hashes.isEmpty, !vaultIDs.isEmpty else { return [] }
        let vMarks = Array(repeating: "?", count: vaultIDs.count).joined(separator: ",")
        var out = Set<String>()
        try dbQueue.read { db in
            var i = 0
            while i < hashes.count {
                let chunk = Array(hashes[i..<min(i + 500, hashes.count)])
                i += 500
                let hMarks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let found = try String.fetchAll(db, sql: """
                    SELECT DISTINCT hash FROM vault_presence
                    WHERE hash IN (\(hMarks)) AND vaultID IN (\(vMarks))
                    """, arguments: StatementArguments(chunk + vaultIDs))
                out.formUnion(found)
            }
        }
        return out
    }

    private static func presenceEntry(_ r: Row) -> VaultPresenceEntry {
        VaultPresenceEntry(hash: r["hash"], relPath: r["relPath"], dirPath: r["dirPath"],
                           size: r["size"], driveRelPath: r["driveRelPath"])
    }
}
