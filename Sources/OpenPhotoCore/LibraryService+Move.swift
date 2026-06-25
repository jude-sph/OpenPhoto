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
        for item in items {
            guard item.driveRelPath == nil else { continue }     // drive-only: caller's job
            guard item.dirPath != destDir else { continue }      // already there
            guard let vault = vault(id: item.vaultID) else {
                result.failures[item.relPath] = "vault not open"; continue
            }
            do {
                let newRel = try VaultReorganizer.moveFile(in: vault, relPath: item.relPath,
                                                           intoDirRelPath: destDir)
                try catalog.rewriteInstancePath(vaultID: item.vaultID,
                                                fromRelPath: item.relPath, toRelPath: newRel)
                result.moved[item.relPath] = newRel
            } catch {
                result.failures[item.relPath] = String(describing: error); continue
            }
            // Best-effort: the Live pair's video travels too (mirrors delete()).
            if let pairHash = item.livePairHash,
               let pair = try? catalog.instanceItem(hash: pairHash, vaultID: item.vaultID),
               pair.dirPath != destDir,
               let newRel = try? VaultReorganizer.moveFile(in: vault, relPath: pair.relPath,
                                                           intoDirRelPath: destDir) {
                try? catalog.rewriteInstancePath(vaultID: item.vaultID,
                                                 fromRelPath: pair.relPath, toRelPath: newRel)
                result.moved[pair.relPath] = newRel
            }
        }
        return result
    }

    /// Reverse a single local file move (`dst` → `src`) on the Mac primary vault: move the file back
    /// (carrying its sidecar + patching the manifest, via `VaultReorganizer.moveFile`) and re-key the
    /// instance in place. No-op when there's no local instance at `dst` (e.g. the photo is drive-only).
    /// The drive is never touched. Used by the reconnect review's "Undo" (drive = ground truth).
    public func revertLocalMove(from dstRelPath: String, to srcRelPath: String) throws {
        guard let vault = vaults.first else { return }
        let vaultID = vault.descriptor.vaultID
        guard catalog.instanceExists(vaultID: vaultID, relPath: dstRelPath) else { return }
        let parent = (srcRelPath as NSString).deletingLastPathComponent
        let newRel = try VaultReorganizer.moveFile(in: vault, relPath: dstRelPath, intoDirRelPath: parent)
        try catalog.rewriteInstancePath(vaultID: vaultID, fromRelPath: dstRelPath, toRelPath: newRel)
    }
}
