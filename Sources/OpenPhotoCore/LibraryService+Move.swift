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
    /// Move local instances into `dest` (vault-root-relative dir, "" = root), each within
    /// its own vault. Carries each Live pair's hidden video half (and both sidecars),
    /// mirroring `delete()`. Items already in `dest` and drive-only items are skipped.
    /// Collects failures and keeps going. Does NOT rescan — the caller orchestrates
    /// (drive propagation first, then one rescan).
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
                result.moved[item.relPath] = try VaultReorganizer.moveFile(
                    in: vault, relPath: item.relPath, intoDirRelPath: destDir)
            } catch {
                result.failures[item.relPath] = String(describing: error); continue
            }
            // Best-effort: the Live pair's video travels too (mirrors delete()).
            if let pairHash = item.livePairHash,
               let pair = try? catalog.instanceItem(hash: pairHash, vaultID: item.vaultID),
               pair.dirPath != destDir,
               let newRel = try? VaultReorganizer.moveFile(in: vault, relPath: pair.relPath,
                                                           intoDirRelPath: destDir) {
                result.moved[pair.relPath] = newRel
            }
        }
        return result
    }
}
