import Foundation

/// A queued deletion resolved against a specific drive, ready to propagate.
public struct PendingDeletion: Sendable, Equatable {
    public let hash: String
    public let relPath: String        // Mac-aligned, for display
    public let driveRelPath: String   // path on the drive (the copy to bin)
    public let size: Int64
    public let deletedAtMs: Int64
    public init(hash: String, relPath: String, driveRelPath: String, size: Int64, deletedAtMs: Int64) {
        self.hash = hash; self.relPath = relPath; self.driveRelPath = driveRelPath
        self.size = size; self.deletedAtMs = deletedAtMs
    }
}

/// Slice 3 — moves locally-deleted photos' drive copies into the drive's bin.
public struct DeletionPropagator: Sendable {
    public init() {}

    public struct Result: Sendable, Equatable {
        public var propagated: Int    // copies actually moved to the drive bin
        public var skipped: Int       // already gone on the drive (still cleared from queue/presence)
        public var failed: Int        // move failed — left queued for retry
        public init(propagated: Int = 0, skipped: Int = 0, failed: Int = 0) {
            self.propagated = propagated; self.skipped = skipped; self.failed = failed
        }
    }

    /// Pure eligibility: queued ∧ no-local-instance ∧ on-drive. Resolves drive path/size
    /// from the drive's presence mirror. No I/O.
    public func eligible(queue: [PendingDeletionRecord],
                         localHashes: Set<String>,
                         presence: [VaultPresenceEntry]) -> [PendingDeletion] {
        let byHash = Dictionary(presence.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        return queue.compactMap { rec in
            guard !localHashes.contains(rec.hash), let p = byHash[rec.hash] else { return nil }
            return PendingDeletion(hash: rec.hash, relPath: p.relPath, driveRelPath: p.driveRelPath,
                                   size: p.size, deletedAtMs: rec.deletedAtMs)
        }
    }

    /// Destructive: move each drive copy into the drive's bin (origin: propagated), then one
    /// atomic manifest rewrite, then update presence + queue + sync-log. A copy already gone is
    /// counted `skipped` but still cleared (goal state reached); a genuine move failure is left
    /// queued for retry. Files move first (each recoverable in the bin), so an interruption before
    /// the manifest rewrite self-heals as a recoverable `missing` drift on the next scan.
    @discardableResult
    public func propagate(drive: Vault, entries: [PendingDeletion],
                          macVaultID: String, catalog: Catalog) throws -> Result {
        guard !entries.isEmpty else { return Result() }
        let bin = BinStore(vault: drive)
        let fm = FileManager.default
        var clearedHashes: [String] = []          // removed from drive (moved OR already gone)
        var clearedDrivePaths = Set<String>()
        var moved = 0, skipped = 0, failed = 0

        for e in entries {
            let src = drive.absoluteURL(forRelativePath: e.driveRelPath)
            if !fm.fileExists(atPath: src.path) {
                skipped += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
                continue
            }
            do {
                try bin.moveToBin(relPath: e.driveRelPath,
                                  hash: ContentHash(stringValue: e.hash), origin: .propagated)
                moved += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
            } catch {
                failed += 1   // leave queued; do not clear
            }
        }

        // One atomic manifest rewrite dropping every cleared path.
        let remaining = try Manifest.read(from: drive.manifestURL)
            .filter { !clearedDrivePaths.contains($0.path) }
        try Manifest.write(remaining, to: drive.manifestURL)

        try catalog.removeVaultPresence(vaultID: drive.descriptor.vaultID, hashes: clearedHashes)
        try catalog.clearPendingDeletions(hashes: clearedHashes)

        if moved > 0 {
            SyncLog.append(event: "delete", summary: "\(moved) propagated to drive bin",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return Result(propagated: moved, skipped: skipped, failed: failed)
    }

    /// Delete photos that exist ONLY on the drive (no local copy, no pending queue): move each
    /// drive file into the drive's bin (`origin: .user` — deleted directly in this vault's UI),
    /// then one atomic manifest rewrite + presence removal + a "delete" sync-log event. Mirrors
    /// `propagate` minus the queue. Returns the count actually binned.
    @discardableResult
    public func deleteDriveOnly(drive: Vault, entries: [(hash: String, driveRelPath: String)],
                                macVaultID: String, catalog: Catalog) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        let bin = BinStore(vault: drive)
        let fm = FileManager.default
        var clearedHashes: [String] = []
        var clearedDrivePaths = Set<String>()
        var moved = 0
        for e in entries {
            let src = drive.absoluteURL(forRelativePath: e.driveRelPath)
            if !fm.fileExists(atPath: src.path) {
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath); continue
            }
            do {
                try bin.moveToBin(relPath: e.driveRelPath,
                                  hash: ContentHash(stringValue: e.hash), origin: .user)
                moved += 1
                clearedHashes.append(e.hash); clearedDrivePaths.insert(e.driveRelPath)
            } catch { /* leave it; not cleared */ }
        }
        let remaining = try Manifest.read(from: drive.manifestURL)
            .filter { !clearedDrivePaths.contains($0.path) }
        try Manifest.write(remaining, to: drive.manifestURL)
        try catalog.removeVaultPresence(vaultID: drive.descriptor.vaultID, hashes: clearedHashes)
        if moved > 0 {
            SyncLog.append(event: "delete", summary: "\(moved) deleted from drive",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return moved
    }
}
