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
        for e in try Manifest.read(from: drive.manifestURL) {
            let h = e.hash.stringValue
            if localHashes.contains(h) || deleted.contains(h) { continue }
            out.insert(Placement(hash: h, path: e.path))
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
