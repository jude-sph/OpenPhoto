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
}
