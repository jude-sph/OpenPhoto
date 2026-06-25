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
    public var failedItems: [FailedItem]
    public var failed: Int { failedItems.count }
    public init(rehydrated: Int = 0, failedItems: [FailedItem] = []) {
        self.rehydrated = rehydrated; self.failedItems = failedItems
    }
}

extension LibraryService {
    /// Release local originals to macOS Trash once verified on a canonical drive. `.verified`
    /// re-hashes the drive copy on a CONNECTED drive; `.forced` trusts `canonicalPresence` (drive
    /// may be absent). Live pairs evict as a unit — both halves must verify or BOTH are refused.
    /// Items not verifiable are refused (kept local). One rescan per touched local vault; the local
    /// sidecar is left in place (rehydrate restores the media beside it).
    @discardableResult
    public func evict(_ items: [TimelineItem], mode: EvictMode,
                      connectedCanonical: [Vault], canonicalPresence: Set<String>,
                      progress: (@Sendable (DriveProgress) -> Void)? = nil,
                      shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> EvictOutcome {
        let local = items.filter { $0.driveRelPath == nil }
        let bytesTotal = local.reduce(Int64(0)) { $0 + $1.size }
        var bytesDone: Int64 = 0
        var filesDone = 0
        var byVault: [String: [TimelineItem]] = [:]
        for it in local { byVault[it.vaultID, default: []].append(it) }
        var outcome = EvictOutcome()
        for (vaultID, group) in byVault {
            guard let localVault = vault(id: vaultID) else { continue }
            var releasedHere = 0
            for item in group {
                if shouldCancel?() == true {
                    if releasedHere > 0 {
                        appendSyncLog(vault: localVault, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
                        try await rescan(vaultID: vaultID)
                    }
                    return outcome
                }
                let name = (item.relPath as NSString).lastPathComponent
                progress?(DriveProgress(stage: .verifying, filesDone: filesDone + 1, filesTotal: local.count,
                                        bytesDone: bytesDone, bytesTotal: bytesTotal, currentName: name))
                var halves: [(hash: String, relPath: String)] = [(item.hash, item.relPath)]
                if let pairHash = item.livePairHash,
                   let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                    halves.append((pairHash, pairInstance.relPath))
                }
                defer { bytesDone += item.size; filesDone += 1 }
                guard halves.allSatisfy({ verifyOnCanonical(hash: $0.hash, mode: mode,
                                                            connectedCanonical: connectedCanonical,
                                                            canonicalPresence: canonicalPresence) })
                else { outcome.refused += 1; continue }
                let stillURL = localVault.absoluteURL(forRelativePath: item.relPath)
                try? FileManager.default.trashItem(at: stillURL, resultingItemURL: nil)
                guard !FileManager.default.fileExists(atPath: stillURL.path) else {
                    outcome.refused += 1; continue
                }
                outcome.evicted += 1; releasedHere += 1
                if halves.count > 1 {
                    try? FileManager.default.trashItem(
                        at: localVault.absoluteURL(forRelativePath: halves[1].relPath), resultingItemURL: nil)
                }
            }
            // Terminal report once a vault's items are all processed: the size-weighted bar
            // catches up to everything released/refused so far (each item's `defer` only advances
            // the counter, the per-item `progress` above reports the pre-item value). The last
            // vault's report reaches `bytesTotal`.
            progress?(DriveProgress(stage: .finishing, filesDone: filesDone, filesTotal: local.count,
                                    bytesDone: bytesDone, bytesTotal: bytesTotal, currentName: ""))
            if releasedHere > 0 {
                appendSyncLog(vault: localVault, event: "evict", summary: "\(releasedHere) released", counterpartyKey: "")
                try await rescan(vaultID: vaultID)
            }
        }
        return outcome
    }

    /// Copy evicted (drive-only) originals back from a connected canonical drive, hash-verified.
    /// Maps each drive path back to the right local vault (the inverse of the basename-strip).
    /// Live pairs rehydrate together (best-effort). One rescan per touched local vault.
    @discardableResult
    public func rehydrate(_ items: [TimelineItem], connectedCanonical: [Vault],
                          progress: (@Sendable (DriveProgress) -> Void)? = nil,
                          shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> RehydrateOutcome {
        var outcome = RehydrateOutcome()
        var restoredPerVault: [String: Int] = [:]
        let targets = items.filter { $0.driveRelPath != nil }
        let bytesTotal = targets.reduce(Int64(0)) { $0 + $1.size }
        var bytesDone: Int64 = 0
        for (i, item) in targets.enumerated() {
            if shouldCancel?() == true { break }
            let name = (item.relPath as NSString).lastPathComponent
            let base = bytesDone
            progress?(DriveProgress(stage: .copying, filesDone: i + 1, filesTotal: targets.count,
                                    bytesDone: base, bytesTotal: bytesTotal, currentName: name))
            func fail(_ reason: SyncFailureReason) {
                outcome.failedItems.append(FailedItem(
                    item: PlanItem(hash: item.hash, sourceURL: URL(fileURLWithPath: item.relPath),
                                   destRelPath: item.relPath, size: item.size), reason: reason))
                bytesDone += item.size
            }
            guard let (drive, stillRow) = driveSource(forHash: item.hash, among: connectedCanonical)
            else { fail(.sourceMissing); continue }
            var halves: [(hash: String, driveRelPath: String, relPath: String)] =
                [(item.hash, stillRow.driveRelPath, item.relPath)]
            if let pairHash = item.livePairHash,
               let row = (try? catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID))?
                    .first(where: { $0.hash == pairHash }) {
                halves.append((pairHash, row.driveRelPath, row.relPath))
            }
            var stillVaultID: String?
            for half in halves {
                guard let (local, localRel) = localTarget(forDriveRelPath: half.driveRelPath, macRelPath: half.relPath)
                else { continue }
                let dest = local.absoluteURL(forRelativePath: localRel)
                if FileManager.default.fileExists(atPath: dest.path) {
                    if half.hash == item.hash { stillVaultID = local.descriptor.vaultID }
                    continue
                }
                let outcome2 = VerifiedCopy.copy(
                    from: drive.absoluteURL(forRelativePath: half.driveRelPath), to: dest,
                    expectedHash: half.hash,
                    onBytes: { fileBytes in
                        progress?(DriveProgress(stage: .copying, filesDone: i + 1, filesTotal: targets.count,
                                                bytesDone: base + fileBytes, bytesTotal: bytesTotal,
                                                currentName: name))
                    },
                    shouldCancel: { shouldCancel?() == true })
                switch outcome2 {
                case .copied: if half.hash == item.hash { stillVaultID = local.descriptor.vaultID }
                // The paired video is best-effort: item success hinges on the still (stillVaultID).
                // A failed/cancelled video doesn't fail the item — the still is back and a later pass
                // (or the post-job driftScan) reconciles the video. Mirrors the original semantics.
                case .cancelled, .failed: break
                }
            }
            bytesDone += item.size
            if let vid = stillVaultID {
                outcome.rehydrated += 1; restoredPerVault[vid, default: 0] += 1
            } else if !(shouldCancel?() == true) {
                outcome.failedItems.append(FailedItem(
                    item: PlanItem(hash: item.hash, sourceURL: drive.absoluteURL(forRelativePath: stillRow.driveRelPath),
                                   destRelPath: item.relPath, size: item.size), reason: .copyFailed))
            }
        }
        for (vid, n) in restoredPerVault {
            if let v = vault(id: vid) {
                appendSyncLog(vault: v, event: "rehydrate", summary: "\(n) restored", counterpartyKey: "")
            }
            try await rescan(vaultID: vid)
        }
        return outcome
    }

    /// Map a drive path back to (local vault, mac-relative path): match the drive path's first
    /// component to a local vault's root basename; otherwise fall back to the primary local vault.
    func localTarget(forDriveRelPath driveRelPath: String, macRelPath: String) -> (Vault, String)? {
        let first = driveRelPath.split(separator: "/").first.map(String.init)
        if let first, let v = vaults.first(where: { $0.rootURL.lastPathComponent == first }) {
            return (v, macRelPath)
        }
        // No basename match: only fall back to the sole vault when it's unambiguous; with several
        // local vaults, refuse rather than risk restoring into the wrong one (caller counts failed).
        guard vaults.count == 1 else { return nil }
        return vaults.first.map { ($0, macRelPath) }
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
