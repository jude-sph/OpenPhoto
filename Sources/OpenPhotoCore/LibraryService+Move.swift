import Foundation

/// Outcome of a per-photo move batch.
public struct MoveResult: Sendable, Equatable {
    /// old relPath → new relPath, for every file actually moved (incl. Live partners).
    public var moved: [String: String] = [:]
    /// relPath → human-readable reason, for files that could not move.
    public var failures: [String: String] = [:]
    public init() {}
}

extension LibraryService {
    /// Move local instances into `dest` (vault-root-relative dir, "" = root), each within its own
    /// vault. Each move atomically: renames the file, carries its XMP sidecar, patches the manifest
    /// entry (all in `VaultReorganizer.moveFile`), and updates the catalog `instances` row in place
    /// (`rewriteInstancePath`). So the caller needs only `refreshQueries()` — no full rescan. Carries
    /// each Live pair's hidden video half too. Items already in `dest` and drive-only items are
    /// skipped. Collects failures and keeps going.
    public func movePhotos(_ items: [TimelineItem], toDir dest: String) -> MoveResult {
        var result = MoveResult()
        let destDir = dest.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Move each file's bytes+sidecar now (collision-safe), but DON'T rewrite the manifest or
        // catalog per file — collect every `old → new` per vault and apply each vault's manifest
        // rewrite + instance re-path ONCE below. An N-file move then costs one manifest read+write
        // and one catalog transaction, not N of each (was O(N · whole-library) for the manifest).
        var pathChanges: [String: [String: String]] = [:]   // vaultID → (old relPath → new relPath)
        for item in items {
            guard item.driveRelPath == nil else { continue }     // drive-only: caller's job
            guard item.dirPath != destDir else { continue }      // already there
            guard let vault = vault(id: item.vaultID) else {
                result.failures[item.relPath] = "vault not open"; continue
            }
            do {
                let newRel = try VaultReorganizer.moveFileNoManifest(in: vault, relPath: item.relPath,
                                                                     intoDirRelPath: destDir)
                pathChanges[item.vaultID, default: [:]][item.relPath] = newRel
                result.moved[item.relPath] = newRel
            } catch {
                result.failures[item.relPath] = String(describing: error); continue
            }
            // Best-effort: the Live pair's video travels too (mirrors delete()).
            if let pairHash = item.livePairHash,
               let pair = try? catalog.instanceItem(hash: pairHash, vaultID: item.vaultID),
               pair.dirPath != destDir,
               let newRel = try? VaultReorganizer.moveFileNoManifest(in: vault, relPath: pair.relPath,
                                                                     intoDirRelPath: destDir) {
                pathChanges[item.vaultID, default: [:]][pair.relPath] = newRel
                result.moved[pair.relPath] = newRel
            }
        }
        // One manifest rewrite + one catalog transaction per vault actually touched. Files already
        // moved on disk above; these commit the index to match. (Best-effort like the per-item path
        // was: a failure here leaves the index stale, which the next rescan reconciles from disk.)
        for (vaultID, mapping) in pathChanges {
            guard !mapping.isEmpty, let vault = vault(id: vaultID) else { continue }
            try? VaultReorganizer.rewriteManifestEntries(vault, mapping: mapping)
            try? catalog.rewriteInstancePaths(vaultID: vaultID, mapping: mapping)
        }
        return result
    }

    /// Reverse a single local file move (`dst` → `src`) on the Mac primary vault: move the file back
    /// (carrying its sidecar + patching the manifest, via `VaultReorganizer.moveFile`) and re-key the
    /// instance in place. No-op when there's no local instance at `dst` (e.g. the photo is drive-only).
    /// The drive is never touched. Returns the path the file actually landed at — usually `src`, but a
    /// collision (something re-occupied `src`) yields a suffixed path; the caller re-keys drive presence
    /// to the RETURNED path so instance + presence stay consistent. Used by the reconnect review's "Undo".
    @discardableResult
    public func revertLocalMove(from dstRelPath: String, to srcRelPath: String) throws -> String {
        guard let vault = vaults.first else { return srcRelPath }
        let vaultID = vault.descriptor.vaultID
        guard catalog.instanceExists(vaultID: vaultID, relPath: dstRelPath) else { return srcRelPath }
        let parent = (srcRelPath as NSString).deletingLastPathComponent
        let newRel = try VaultReorganizer.moveFile(in: vault, relPath: dstRelPath, intoDirRelPath: parent)
        try catalog.rewriteInstancePath(vaultID: vaultID, fromRelPath: dstRelPath, toRelPath: newRel)
        return newRel
    }
}
