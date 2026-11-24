import Foundation

/// Provably-lossless removal of a REDUNDANT drive folder — the "stale old path" a folder move leaves
/// behind when it half-applies on a drive (see the drive-reconcile-by-state design; this is that
/// design's "in ACTUAL, not in DESIRED, hash desired elsewhere → remove stale" case, done as a
/// verified one-off).
///
/// The safety rule is absolute and checked in code: for EVERY real media file physically in the
/// folder, hash the actual bytes and require a byte-verified identical copy to still exist *outside*
/// the folder — a local instance on the Mac (ground truth), or a sibling on the SAME drive. If any
/// single file lacks such a survivor, NOTHING is removed (all-or-nothing). Removal then bins each file
/// on the drive (recoverable), and drops manifest + presence entries BY PATH so a shared hash's
/// surviving placements keep their rows. Honors the invariants: nothing hard-deletes, writes are
/// atomic, and it is one-way (drive is passive).
public enum RedundantDriveFolderCleaner {

    /// A file proven safe to remove: `survivor` is a byte-verified copy that outlives the removal,
    /// labelled `"local:<relPath>"` (on the Mac) or `"drive:<driveRelPath>"` (elsewhere on this drive).
    public struct Proven: Sendable, Equatable {
        public let driveRelPath: String
        public let hash: String
        public let survivor: String
    }
    /// A file that blocks the whole operation — no byte-verified copy survives its removal.
    public struct Blocked: Sendable, Equatable {
        public let driveRelPath: String
        public let hash: String
        public let reason: String
    }
    public struct Assessment: Sendable, Equatable {
        public var proven: [Proven]
        public var blocked: [Blocked]
        /// Safe only if every file in the folder has a proven survivor (and the folder holds ≥1 file).
        public var isSafe: Bool { blocked.isEmpty && !proven.isEmpty }
    }

    // MARK: Assess (read-only proof)

    /// Hash every real media file under `folderRelPath` on `drive`; for each, find a byte-verified
    /// surviving copy (local first, then a same-drive sibling *outside* the folder). Touches nothing.
    /// `localVault` may be nil (a drive-only setup) — then only same-drive siblings can vouch.
    public static func assess(drive: Vault, folderRelPath: String,
                              localVault: Vault?, catalog: Catalog) throws -> Assessment {
        let folder = norm(folderRelPath)
        guard !folder.isEmpty else { return Assessment(proven: [], blocked: []) }
        let folderPrefix = folder + "/"
        var proven: [Proven] = []
        var blocked: [Blocked] = []

        for rel in mediaFiles(under: folder, in: drive).sorted() {
            let hash: String
            do { hash = try ContentHash.ofFile(at: drive.absoluteURL(forRelativePath: rel)).stringValue }
            catch {
                blocked.append(Blocked(driveRelPath: rel, hash: "", reason: "unreadable: \(error)"))
                continue
            }
            if let survivor = try survivor(forHash: hash, drive: drive, folder: folder,
                                           folderPrefix: folderPrefix, localVault: localVault,
                                           catalog: catalog) {
                proven.append(Proven(driveRelPath: rel, hash: hash, survivor: survivor))
            } else {
                blocked.append(Blocked(driveRelPath: rel, hash: hash,
                                       reason: "no byte-verified surviving copy outside this folder"))
            }
        }
        return Assessment(proven: proven, blocked: blocked)
    }

    // MARK: Remove (gated on the proof)

    /// Assess, and only if the folder is proven fully redundant, remove it: bin each file on the drive
    /// (`origin .repaired`, recoverable), one atomic manifest rewrite dropping the folder's paths,
    /// remove the folder's presence rows BY PATH, prune the empty husk, log a sync event. Returns the
    /// assessment acted on — `isSafe == false` ⇒ nothing changed.
    @discardableResult
    public static func removeIfProvenRedundant(drive: Vault, folderRelPath: String,
                                               localVault: Vault?, catalog: Catalog,
                                               macVaultID: String) throws -> Assessment {
        let assessment = try assess(drive: drive, folderRelPath: folderRelPath,
                                    localVault: localVault, catalog: catalog)
        guard assessment.isSafe else { return assessment }

        let folder = norm(folderRelPath)
        let folderPrefix = folder + "/"
        let bin = BinStore(vault: drive)

        // Files first — each lands recoverable in the bin, so an interruption before the manifest
        // rewrite self-heals as a recoverable `missing` on the next scan (same discipline as deletions).
        // One bin-log rewrite for the whole folder (not one per file). Any failure still aborts
        // before the manifest is touched; files already binned stay recoverable.
        let binFailures = bin.moveToBin(assessment.proven.map {
            BinStore.BinMove(relPath: $0.driveRelPath, hash: ContentHash(stringValue: $0.hash),
                             origin: .repaired)
        })
        if let first = binFailures.min(by: { $0.key < $1.key }) { throw first.value }

        // One atomic manifest rewrite: drop every entry under the folder.
        let remaining = try Manifest.read(from: drive.manifestURL)
            .filter { !($0.path == folder || $0.path.hasPrefix(folderPrefix)) }
        try Manifest.write(remaining, to: drive.manifestURL)

        // Drop presence rows for the folder BY PATH (a shared hash's survivors keep their rows).
        let stalePaths = try catalog.vaultPresenceRows(forVault: drive.id)
            .map(\.driveRelPath)
            .filter { $0 == folder || $0.hasPrefix(folderPrefix) }
        try catalog.removeVaultPresence(vaultID: drive.id, driveRelPaths: stalePaths)

        VaultReorganizer.pruneEmptyDirs(in: drive, under: folder)
        SyncLog.append(event: "reconcile",
                       summary: "removed \(assessment.proven.count) redundant copies from \(folder)",
                       counterparty: macVaultID, to: drive.syncLogURL)
        return assessment
    }

    // MARK: Internals

    /// A byte-verified copy of `hash` that will still exist after the folder is removed, or nil.
    /// Prefers a local copy (the Mac is ground truth), then a same-drive sibling outside the folder.
    private static func survivor(forHash hash: String, drive: Vault, folder: String,
                                 folderPrefix: String, localVault: Vault?,
                                 catalog: Catalog) throws -> String? {
        let fm = FileManager.default
        if let lv = localVault {
            for rel in try catalog.instanceRelPaths(vaultID: lv.id, hash: hash) {
                let url = lv.absoluteURL(forRelativePath: rel)
                if fm.fileExists(atPath: url.path),
                   (try? ContentHash.ofFile(at: url).stringValue) == hash { return "local:" + rel }
            }
        }
        for p in try catalog.vaultPresenceDriveRelPaths(vaultID: drive.id, hash: hash) {
            if p == folder || p.hasPrefix(folderPrefix) { continue }   // in-folder copies can't vouch
            let url = drive.absoluteURL(forRelativePath: p)
            if fm.fileExists(atPath: url.path),
               (try? ContentHash.ofFile(at: url).stringValue) == hash { return "drive:" + p }
        }
        return nil
    }

    /// Real media files (drive-root-relative paths) physically under `folder`, skipping hidden entries
    /// — which excludes `.openphoto/` sidecar dirs and macOS `._` AppleDouble stubs.
    private static func mediaFiles(under folder: String, in drive: Vault) -> [String] {
        let fm = FileManager.default
        let root = drive.absoluteURL(forRelativePath: folder)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in en {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            out.append(drive.relativePath(of: u))
        }
        return out
    }

    private static func norm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
