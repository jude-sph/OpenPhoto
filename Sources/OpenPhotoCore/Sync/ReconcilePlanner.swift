import Foundation

/// Production adapter that turns the catalog + a drive into a `ReconcilePlan` — the bridge between the
/// pure `computeReconcilePlan` and any caller (a dry-run preview, the reconnect flow). Read-only.
///
/// DESIRED (what the drive should hold) = every LOCAL instance mapped to its drive path the same way
/// sync places files (`SyncEngine.driveRelPath`), PLUS any drive-only content (no local instance) kept
/// as a retained evicted original — UNLESS it's a genuine deletion queued in `pending_deletions`.
///
/// This encodes the two rules exactly: a **delete** on the Mac (queued) is excluded from DESIRED, so
/// the plan removes it from the drive; an **eviction** (drive-only, never queued) stays in DESIRED, so
/// the drive copy is never touched. Genuine deletions surface as the plan's `reviewDeletions`, which
/// `ReconcileExecutor.apply` honors (bin, recoverable) behind the blast-radius guard.
public enum ReconcilePlanner {

    /// The library's placements as drive paths.
    ///
    /// Drive-only content follows the Mac's moves of it: moving an evicted photo (or a folder holding
    /// some) re-keys that drive's presence rows onto the new path (`relPath` and `driveRelPath`) and
    /// queues an op, while the drive's manifest still lists the old path. For a drive-only hash, each
    /// manifest path with no presence row is paired (sorted, like relocations) with a presence path the
    /// manifest lacks, and the content is desired at the presence path — so the plan relocates it
    /// rather than the post-reconcile presence projection silently reverting the move. Unpaired
    /// manifest paths stay desired as they are (conservative: an evicted original is never dropped).
    public static func desired(drive: Vault, localVault: Vault, catalog: Catalog) throws -> Set<Placement> {
        var out = Set<Placement>()
        var localHashes = Set<String>()
        for (h, rel) in try catalog.instanceHashPaths(vaultID: localVault.id) {
            localHashes.insert(h)
            out.insert(Placement(hash: h, path: SyncEngine.driveRelPath(forSourceVault: localVault, relPath: rel)))
        }
        // Drive-only content: keep (evicted original) unless it's a queued deletion (honor it). Read
        // from the manifest — the faithful multi-path record (vault_presence is deduped per hash).
        let deleted = Set(try catalog.pendingDeletions().map(\.hash))
        var manifestPaths: [String: Set<String>] = [:]          // drive-only hash -> manifest paths
        for e in try Manifest.read(from: drive.manifestURL) {
            let h = e.hash.stringValue
            if localHashes.contains(h) || deleted.contains(h) { continue }
            manifestPaths[h, default: []].insert(e.path)
        }
        var presencePaths: [String: Set<String>] = [:]
        for row in try catalog.vaultPresenceRows(forVault: drive.id) where manifestPaths[row.hash] != nil {
            presencePaths[row.hash, default: []].insert(row.driveRelPath)
        }
        for (h, m) in manifestPaths {
            let p = presencePaths[h] ?? []
            let moved = m.subtracting(p).sorted(), movedTo = p.subtracting(m).sorted()
            let paired = min(moved.count, movedTo.count)
            for path in m where !moved.prefix(paired).contains(path) {
                out.insert(Placement(hash: h, path: path))
            }
            for path in movedTo.prefix(paired) { out.insert(Placement(hash: h, path: path)) }
        }
        return out
    }

    /// The drive's current placements, from its manifest.
    public static func actual(drive: Vault) throws -> Set<Placement> {
        Set(try Manifest.read(from: drive.manifestURL).map { Placement(hash: $0.hash.stringValue, path: $0.path) })
    }

    /// The plan to make `drive` mirror the library. Pure read — touches nothing.
    public static func plan(drive: Vault, localVault: Vault, catalog: Catalog) throws -> ReconcilePlan {
        computeReconcilePlan(desired: try desired(drive: drive, localVault: localVault, catalog: catalog),
                             actual: try actual(drive: drive))
    }
}
