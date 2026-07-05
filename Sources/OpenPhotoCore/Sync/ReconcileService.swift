import Foundation

/// One-call reconcile of a drive against the library — the integration point the app invokes on
/// reconnect/sync (in the background, behind a progress bar). It replaces op-replay: instead of
/// replaying a queue of past actions, it computes the drive-vs-library difference by content and makes
/// the drive match.
///
/// plan → apply (copy in / relocate / remove stale / honor deletions) → project presence from the
/// reconciled manifest. Presence is a *projection* of the manifest ("derived, not maintained"), so the
/// old "rebuild presence then reapply ops" dance disappears.
public enum ReconcileService {

    /// Reconcile `drive` to mirror the library. Off-main safe. `sourceBasenames` are the library's
    /// vault-root basenames (for mapping drive paths back to Mac-aligned relPaths) — pass every source
    /// vault's `rootURL.lastPathComponent`. Returns the executor result (counts + any blast-radius
    /// block). Nothing is projected when the run is blocked.
    @discardableResult
    public static func reconcile(drive: Vault, localVault: Vault, catalog: Catalog,
                                 sourceBasenames: [String], macVaultID: String,
                                 maxDeletionFraction: Double = 0.25) throws -> ReconcileExecutor.Result {
        let plan = try ReconcilePlanner.plan(drive: drive, localVault: localVault, catalog: catalog)
        let actualCount = try Manifest.read(from: drive.manifestURL).count
        let result = try ReconcileExecutor.apply(plan: plan, drive: drive, localVault: localVault,
                                                 catalog: catalog, actualCount: actualCount,
                                                 macVaultID: macVaultID, maxDeletionFraction: maxDeletionFraction)
        if !result.blockedByBlastRadius {
            try projectPresence(drive: drive, catalog: catalog, sourceBasenames: sourceBasenames)
        }
        return result
    }

    /// Rebuild `drive`'s `vault_presence` as a projection of its (reconciled) manifest — the same
    /// mapping the reconnect rebuild uses: `driveRelPath` = the raw manifest path, `relPath` =
    /// Mac-aligned via `DrivePathMap.driveToMacRelPath`. One write transaction.
    static func projectPresence(drive: Vault, catalog: Catalog, sourceBasenames: [String]) throws {
        let entries = try Manifest.read(from: drive.manifestURL).map { e -> VaultPresenceEntry in
            let mac = DrivePathMap.driveToMacRelPath(e.path, sourceBasenames: sourceBasenames)
            return VaultPresenceEntry(hash: e.hash.stringValue, relPath: mac,
                                      dirPath: (mac as NSString).deletingLastPathComponent,
                                      size: e.size, driveRelPath: e.path)
        }
        try catalog.replaceVaultPresence(vaultID: drive.id, entries: entries)
    }
}
