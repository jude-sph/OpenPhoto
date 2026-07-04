import Foundation

/// Phase 2 of the drive-mirroring rewrite: applying a `ReconcilePlan`'s AUTO-SAFE, verified actions to
/// a drive. This turn implements the operation a mirror actually needs to self-heal move-orphans —
/// stale-removals — with the same discipline as `RedundantDriveFolderCleaner`: PROVE on disk before
/// removing (Decision 3). Relocations and copies are counted as pending (next slice); genuine deletions
/// are NEVER auto-applied — they're returned for review. A high genuine-deletion blast-radius blocks all
/// destructive work, since it signals the catalog (hence the whole plan) can't be trusted.
public enum ReconcileExecutor {

    public struct RemovalResult: Equatable, Sendable {
        public var removed: Int        // binned (verified hash + verified survivor)
        public var skipped: Int        // could not verify → left in place (safe)
        public var alreadyGone: Int    // no file on disk → records cleared, goal reached
        public init(removed: Int = 0, skipped: Int = 0, alreadyGone: Int = 0) {
            self.removed = removed; self.skipped = skipped; self.alreadyGone = alreadyGone
        }
    }

    public struct Result: Equatable, Sendable {
        public var staleRemoved: Int
        public var staleSkipped: Int
        public var staleAlreadyGone: Int
        public var relocationsPending: Int
        public var copiesPending: Int
        public var deletionsForReview: [Placement]
        public var blockedByBlastRadius: Bool
        public init(staleRemoved: Int = 0, staleSkipped: Int = 0, staleAlreadyGone: Int = 0,
                    relocationsPending: Int = 0, copiesPending: Int = 0,
                    deletionsForReview: [Placement] = [], blockedByBlastRadius: Bool = false) {
            self.staleRemoved = staleRemoved; self.staleSkipped = staleSkipped
            self.staleAlreadyGone = staleAlreadyGone; self.relocationsPending = relocationsPending
            self.copiesPending = copiesPending; self.deletionsForReview = deletionsForReview
            self.blockedByBlastRadius = blockedByBlastRadius
        }
    }

    /// Apply the verified-safe parts of `plan`. Genuine deletions are surfaced, never executed. If they
    /// exceed `maxDeletionFraction` of the drive, nothing destructive runs (the plan is untrustworthy).
    @discardableResult
    public static func apply(plan: ReconcilePlan, drive: Vault, localVault: Vault?, catalog: Catalog,
                             actualCount: Int, macVaultID: String,
                             maxDeletionFraction: Double = 0.25) throws -> Result {
        let deletionFraction = actualCount > 0
            ? Double(plan.reviewDeletions.count) / Double(actualCount) : 0
        if deletionFraction > maxDeletionFraction {
            return Result(deletionsForReview: plan.reviewDeletions, blockedByBlastRadius: true)
        }
        let rr = try applyStaleRemovals(plan.staleRemovals, drive: drive, localVault: localVault,
                                        catalog: catalog, macVaultID: macVaultID)
        return Result(staleRemoved: rr.removed, staleSkipped: rr.skipped, staleAlreadyGone: rr.alreadyGone,
                      relocationsPending: plan.relocations.count, copiesPending: plan.copies.count,
                      deletionsForReview: plan.reviewDeletions, blockedByBlastRadius: false)
    }

    /// Bin the plan's stale copies, each proven redundant ON DISK first: the file must hash to the
    /// expected value AND an identical copy must physically survive at a path NOT in the removal set (a
    /// local instance, or another drive path). Unverifiable files are skipped, never removed. One atomic
    /// manifest rewrite + by-path presence removal for the binned/already-gone set.
    @discardableResult
    public static func applyStaleRemovals(_ removals: [Placement], drive: Vault, localVault: Vault?,
                                          catalog: Catalog, macVaultID: String) throws -> RemovalResult {
        guard !removals.isEmpty else { return RemovalResult() }
        let fm = FileManager.default
        let bin = BinStore(vault: drive)
        let removingPaths = Set(removals.map(\.path))
        var removed = 0, skipped = 0, alreadyGone = 0
        var clearedPaths = Set<String>()

        for r in removals {
            let url = drive.absoluteURL(forRelativePath: r.path)
            if !fm.fileExists(atPath: url.path) {
                alreadyGone += 1; clearedPaths.insert(r.path); continue
            }
            // The file must be exactly the content the plan means to drop.
            guard let onDisk = try? ContentHash.ofFile(at: url).stringValue, onDisk == r.hash else {
                skipped += 1; continue
            }
            // …and an identical copy must survive OUTSIDE the removal set.
            guard try survivorExists(hash: r.hash, excluding: removingPaths, drive: drive,
                                     localVault: localVault, catalog: catalog) else {
                skipped += 1; continue
            }
            do {
                try bin.moveToBin(relPath: r.path, hash: ContentHash(stringValue: r.hash), origin: .repaired)
                removed += 1; clearedPaths.insert(r.path)
            } catch { skipped += 1 }   // leave it; not cleared
        }

        if !clearedPaths.isEmpty {
            let remaining = try Manifest.read(from: drive.manifestURL).filter { !clearedPaths.contains($0.path) }
            try Manifest.write(remaining, to: drive.manifestURL)
            try catalog.removeVaultPresence(vaultID: drive.id, driveRelPaths: Array(clearedPaths))
            pruneEmptyAncestors(of: clearedPaths, in: drive)   // no empty phantom folders left behind
        }
        if removed > 0 {
            SyncLog.append(event: "reconcile", summary: "removed \(removed) stale copies",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return RemovalResult(removed: removed, skipped: skipped, alreadyGone: alreadyGone)
    }

    /// Remove husk directories the removals emptied, deepest-first. `deleteEmptyFolder` refuses any dir
    /// still holding media (ignoring `.openphoto`/dotfiles), so a shared ancestor like the library root
    /// is never touched — only genuinely-empty leftovers are cleaned.
    private static func pruneEmptyAncestors(of paths: Set<String>, in drive: Vault) {
        var dirs = Set<String>()
        for p in paths {
            var dir = (p as NSString).deletingLastPathComponent
            while !dir.isEmpty { dirs.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        for d in dirs.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            try? VaultReorganizer.deleteEmptyFolder(in: drive, relPath: d)
        }
    }

    /// True iff a byte-verified copy of `hash` physically exists at a path NOT being removed — a local
    /// instance (ground truth) or another drive path. Same proof the folder cleaner uses.
    private static func survivorExists(hash: String, excluding removing: Set<String>, drive: Vault,
                                       localVault: Vault?, catalog: Catalog) throws -> Bool {
        let fm = FileManager.default
        if let lv = localVault {
            for rel in try catalog.instanceRelPaths(vaultID: lv.id, hash: hash) {
                let url = lv.absoluteURL(forRelativePath: rel)
                if fm.fileExists(atPath: url.path),
                   (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
            }
        }
        for p in try catalog.vaultPresenceDriveRelPaths(vaultID: drive.id, hash: hash) where !removing.contains(p) {
            let url = drive.absoluteURL(forRelativePath: p)
            if fm.fileExists(atPath: url.path),
               (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
        }
        return false
    }
}
