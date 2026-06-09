import Foundation

public enum EvictMode: String, Sendable {
    case verified   // requires a connected canonical drive; re-hashes the drive copy
    case forced     // trusts the recorded hash; the drive may be absent
}

public struct EvictOutcome: Sendable, Equatable {
    public var evicted: Int   // local originals released to macOS Trash
    public var refused: Int   // not verifiable on a canonical drive → kept local
    public init(evicted: Int = 0, refused: Int = 0) { self.evicted = evicted; self.refused = refused }
}

public struct RehydrateOutcome: Sendable, Equatable {
    public var rehydrated: Int
    public var failed: Int
    public init(rehydrated: Int = 0, failed: Int = 0) { self.rehydrated = rehydrated; self.failed = failed }
}

extension LibraryService {
    /// Release local originals to macOS Trash once verified on a canonical drive. `.verified`
    /// re-hashes the drive copy on a CONNECTED drive; `.forced` trusts `canonicalPresence` (drive
    /// may be absent). Live pairs evict as a unit — both halves must verify or BOTH are refused.
    /// Items not verifiable are refused (kept local). One rescan per touched local vault; the local
    /// sidecar is left in place (rehydrate restores the media beside it).
    @discardableResult
    public func evict(_ items: [TimelineItem], mode: EvictMode,
                      connectedCanonical: [Vault], canonicalPresence: Set<String>) async throws -> EvictOutcome {
        var byVault: [String: [TimelineItem]] = [:]
        for it in items where it.driveRelPath == nil { byVault[it.vaultID, default: []].append(it) }
        var outcome = EvictOutcome()
        for (vaultID, group) in byVault {
            guard let local = vault(id: vaultID) else { continue }
            var releasedHere = 0
            for item in group {
                var halves: [(hash: String, relPath: String)] = [(item.hash, item.relPath)]
                if let pairHash = item.livePairHash,
                   let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                    halves.append((pairHash, pairInstance.relPath))
                }
                guard halves.allSatisfy({ verifyOnCanonical(hash: $0.hash, mode: mode,
                                                            connectedCanonical: connectedCanonical,
                                                            canonicalPresence: canonicalPresence) })
                else { outcome.refused += 1; continue }
                let stillURL = local.absoluteURL(forRelativePath: item.relPath)
                try? FileManager.default.trashItem(at: stillURL, resultingItemURL: nil)
                // Success = the file is gone afterward. A trash that fails for a real reason
                // leaves the file in place → refused (counted, kept). An already-absent local
                // file passes here and is counted released: it's verified on the drive, and the
                // rescan below correctly transitions the asset to drive-only.
                guard !FileManager.default.fileExists(atPath: stillURL.path) else {
                    outcome.refused += 1; continue
                }
                outcome.evicted += 1; releasedHere += 1
                // The paired video goes too. Best-effort (already verified above): a rare failure
                // here leaves the local video to be released on a later pass — never lost, since
                // it's confirmed on the drive — rather than un-counting the released still.
                if halves.count > 1 {
                    try? FileManager.default.trashItem(
                        at: local.absoluteURL(forRelativePath: halves[1].relPath), resultingItemURL: nil)
                }
            }
            if releasedHere > 0 {
                appendSyncLog(vault: local, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
                try await rescan(vaultID: vaultID)
            }
        }
        return outcome
    }

    /// Whether `hash`'s copy on a canonical drive can be trusted right now under `mode`.
    func verifyOnCanonical(hash: String, mode: EvictMode,
                           connectedCanonical: [Vault], canonicalPresence: Set<String>) -> Bool {
        switch mode {
        case .forced:
            return canonicalPresence.contains(hash)
        case .verified:
            for drive in connectedCanonical {
                guard let row = (try? catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                        .first(where: { $0.hash == hash }) else { continue }
                let url = drive.absoluteURL(forRelativePath: row.driveRelPath)
                if (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
            }
            return false
        }
    }
}
