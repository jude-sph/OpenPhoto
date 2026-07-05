import Foundation

/// Production adapter that turns the catalog + a drive into a `ReconcilePlan` — the bridge between the
/// pure `computeReconcilePlan` and any caller (a dry-run preview, the reconnect flow). Read-only.
///
/// DESIRED (what the drive should hold) = every LOCAL instance mapped to its drive path the same way
/// sync places files (`SyncEngine.driveRelPath`), PLUS any drive placement with no local instance,
/// kept as a retained evicted original. That last rule is deliberately CONSERVATIVE: reconcile here
/// never proposes deleting drive-only content — genuine-deletion detection stays with the existing
/// deletion path — so a plan from this planner only ever copies, relocates, or removes stale duplicates.
public enum ReconcilePlanner {

    /// The library's placements as drive paths.
    public static func desired(drive: Vault, localVault: Vault, catalog: Catalog) throws -> Set<Placement> {
        var out = Set<Placement>()
        var localHashes = Set<String>()
        for (h, rel) in try catalog.instanceHashPaths(vaultID: localVault.id) {
            localHashes.insert(h)
            out.insert(Placement(hash: h, path: SyncEngine.driveRelPath(forSourceVault: localVault, relPath: rel)))
        }
        // Evicted originals (no local instance) are still wanted — keep them at their current drive path.
        for p in try catalog.vaultPresenceRows(forVault: drive.id) where !localHashes.contains(p.hash) {
            out.insert(Placement(hash: p.hash, path: p.driveRelPath))
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
