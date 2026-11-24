import Foundation

/// Phase 2 of the drive-mirroring rewrite: applying a `ReconcilePlan`'s AUTO-SAFE, verified actions to
/// a drive. This turn implements the operation a mirror actually needs to self-heal move-orphans —
/// stale-removals — with the same discipline as `RedundantDriveFolderCleaner`: PROVE on disk before
/// removing (Decision 3). `apply` runs all of: copies in, relocations, stale removals, genuine deletions
/// (binned on the drive, recoverable) and sidecar updates. A high genuine-deletion blast-radius blocks
/// the whole run, since it signals the catalog (hence the whole plan) can't be trusted.
public enum ReconcileExecutor {

    public struct RemovalResult: Equatable, Sendable {
        public var removed: Int        // binned (verified hash + verified survivor)
        public var skipped: Int        // could not verify → left in place (safe)
        public var alreadyGone: Int    // no file on disk → records cleared, goal reached
        public init(removed: Int = 0, skipped: Int = 0, alreadyGone: Int = 0) {
            self.removed = removed; self.skipped = skipped; self.alreadyGone = alreadyGone
        }
    }

    public struct Result: Equatable, Sendable {
        public var staleRemoved: Int
        public var staleSkipped: Int
        public var staleAlreadyGone: Int
        public var relocated: Int
        public var copied: Int
        public var copySkipped: Int
        public var deletionsApplied: Int
        public var sidecarsUpdated: Int
        public var blockedByBlastRadius: Bool
        public var blockedDeletions: [Placement]   // populated only when blast-radius blocks the run
        public init(staleRemoved: Int = 0, staleSkipped: Int = 0, staleAlreadyGone: Int = 0,
                    relocated: Int = 0, copied: Int = 0, copySkipped: Int = 0, deletionsApplied: Int = 0,
                    sidecarsUpdated: Int = 0,
                    blockedByBlastRadius: Bool = false, blockedDeletions: [Placement] = []) {
            self.staleRemoved = staleRemoved; self.staleSkipped = staleSkipped
            self.staleAlreadyGone = staleAlreadyGone; self.relocated = relocated
            self.copied = copied; self.copySkipped = copySkipped; self.deletionsApplied = deletionsApplied
            self.sidecarsUpdated = sidecarsUpdated
            self.blockedByBlastRadius = blockedByBlastRadius; self.blockedDeletions = blockedDeletions
        }
    }

    /// Apply a full `plan` to make the drive mirror the library: copy in, relocate, remove stale, then
    /// honor genuine deletions (bin the drive copy — a delete on the Mac propagates to the drive). Every
    /// destructive step verifies on disk first and bins recoverably. If genuine deletions exceed
    /// `maxDeletionFraction` of the drive, NOTHING runs — that scale of "disappeared" content means the
    /// catalog (hence the plan) can't be trusted; the blocked deletions are returned for a human to see.
    @discardableResult
    public static func apply(plan: ReconcilePlan, drive: Vault, localVault: Vault?, catalog: Catalog,
                             actualCount: Int, macVaultID: String,
                             maxDeletionFraction: Double = 0.25) throws -> Result {
        let deletionFraction = actualCount > 0
            ? Double(plan.reviewDeletions.count) / Double(actualCount) : 0
        if deletionFraction > maxDeletionFraction {
            return Result(blockedByBlastRadius: true, blockedDeletions: plan.reviewDeletions)
        }
        // Order (design Decision 5): copy in → relocate → remove stale → delete. Each atomic + verified.
        let cp = try applyCopies(plan.copies, drive: drive, localVault: localVault,
                                 catalog: catalog, macVaultID: macVaultID)
        let rel = try applyRelocations(plan.relocations, drive: drive, macVaultID: macVaultID)
        let sr = try applyStaleRemovals(plan.staleRemovals, drive: drive, localVault: localVault,
                                        catalog: catalog, macVaultID: macVaultID)
        let del = try applyDeletions(plan.reviewDeletions, drive: drive, catalog: catalog, macVaultID: macVaultID)
        // Last: mirror sidecar edits for photos the drive already holds (after relocations, so the
        // sidecar lands beside the media's final path).
        let sc = try applySidecarUpdates(drive: drive, localVault: localVault, catalog: catalog,
                                         macVaultID: macVaultID)
        return Result(staleRemoved: sr.removed, staleSkipped: sr.skipped, staleAlreadyGone: sr.alreadyGone,
                      relocated: rel, copied: cp.copied, copySkipped: cp.skipped, deletionsApplied: del,
                      sidecarsUpdated: sc)
    }

    /// Honor genuine deletions on the drive: bin each deleted photo's drive copy (origin `.propagated`,
    /// recoverable), verifying on disk that the file is the content we mean to remove first. One atomic
    /// manifest rewrite + by-path presence removal + husk prune, then clear the pending-deletion intent
    /// for hashes no drive holds anymore. (Eviction never reaches here — it's excluded from the plan.)
    @discardableResult
    public static func applyDeletions(_ deletions: [Placement], drive: Vault, catalog: Catalog,
                                      macVaultID: String) throws -> Int {
        guard !deletions.isEmpty else { return 0 }
        let fm = FileManager.default
        let bin = BinStore(vault: drive)
        var clearedPaths = Set<String>()
        var clearedHashes: [String] = []
        var binned = 0
        for d in deletions {
            let url = drive.absoluteURL(forRelativePath: d.path)
            if !fm.fileExists(atPath: url.path) {
                clearedPaths.insert(d.path); clearedHashes.append(d.hash); continue
            }
            guard (try? ContentHash.ofFile(at: url).stringValue) == d.hash else { continue }  // drift → skip
            do {
                try bin.moveToBin(relPath: d.path, hash: ContentHash(stringValue: d.hash), origin: .propagated)
                binned += 1; clearedPaths.insert(d.path); clearedHashes.append(d.hash)
            } catch { /* leave; not cleared */ }
        }
        if !clearedPaths.isEmpty {
            let remaining = try Manifest.read(from: drive.manifestURL).filter { !clearedPaths.contains($0.path) }
            try Manifest.write(remaining, to: drive.manifestURL)
            try catalog.removeVaultPresence(vaultID: drive.id, driveRelPaths: Array(clearedPaths))
            pruneEmptyAncestors(of: clearedPaths, in: drive)
            try catalog.clearPendingDeletionsWithoutPresence(hashes: clearedHashes)
        }
        if binned > 0 {
            SyncLog.append(event: "reconcile", summary: "removed \(binned) deleted photos from drive",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return binned
    }

    /// Bin the plan's stale copies, each proven redundant ON DISK first: the file must hash to the
    /// expected value AND an identical copy must physically survive at a path NOT in the removal set (a
    /// local instance, or another drive path). Unverifiable files are skipped, never removed. One atomic
    /// manifest rewrite + by-path presence removal for the binned/already-gone set.
    @discardableResult
    public static func applyStaleRemovals(_ removals: [Placement], drive: Vault, localVault: Vault?,
                                          catalog: Catalog, macVaultID: String) throws -> RemovalResult {
        guard !removals.isEmpty else { return RemovalResult() }
        let fm = FileManager.default
        let bin = BinStore(vault: drive)
        let removingPaths = Set(removals.map(\.path))
        var removed = 0, skipped = 0, alreadyGone = 0
        var clearedPaths = Set<String>()

        for r in removals {
            let url = drive.absoluteURL(forRelativePath: r.path)
            if !fm.fileExists(atPath: url.path) {
                alreadyGone += 1; clearedPaths.insert(r.path); continue
            }
            // The file must be exactly the content the plan means to drop.
            guard let onDisk = try? ContentHash.ofFile(at: url).stringValue, onDisk == r.hash else {
                skipped += 1; continue
            }
            // …and an identical copy must survive OUTSIDE the removal set.
            guard try survivorExists(hash: r.hash, excluding: removingPaths, drive: drive,
                                     localVault: localVault, catalog: catalog) else {
                skipped += 1; continue
            }
            do {
                try bin.moveToBin(relPath: r.path, hash: ContentHash(stringValue: r.hash), origin: .repaired)
                removed += 1; clearedPaths.insert(r.path)
            } catch { skipped += 1 }   // leave it; not cleared
        }

        if !clearedPaths.isEmpty {
            let remaining = try Manifest.read(from: drive.manifestURL).filter { !clearedPaths.contains($0.path) }
            try Manifest.write(remaining, to: drive.manifestURL)
            try catalog.removeVaultPresence(vaultID: drive.id, driveRelPaths: Array(clearedPaths))
            pruneEmptyAncestors(of: clearedPaths, in: drive)   // no empty phantom folders left behind
        }
        if removed > 0 {
            SyncLog.append(event: "reconcile", summary: "removed \(removed) stale copies",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return RemovalResult(removed: removed, skipped: skipped, alreadyGone: alreadyGone)
    }

    public struct CopyResult: Equatable, Sendable {
        public var copied: Int
        public var skipped: Int
        public init(copied: Int = 0, skipped: Int = 0) { self.copied = copied; self.skipped = skipped }
    }

    /// Apply the plan's relocations: a same-hash move already on the drive. Verify each source on disk
    /// hashes to the expected value (a content-preserving rename follows), then relocate file + sidecar
    /// via `moveFilesExact` (collision-safe, one atomic manifest rewrite). Returns the count moved.
    @discardableResult
    public static func applyRelocations(_ relocations: [ReconcilePlan.Relocation], drive: Vault,
                                        macVaultID: String) throws -> Int {
        guard !relocations.isEmpty else { return 0 }
        let fm = FileManager.default
        var moves: [(from: String, to: String)] = []
        for r in relocations {
            let fromURL = drive.absoluteURL(forRelativePath: r.from)
            guard fm.fileExists(atPath: fromURL.path),
                  (try? ContentHash.ofFile(at: fromURL).stringValue) == r.hash else { continue }
            moves.append((from: r.from, to: r.to))
        }
        guard !moves.isEmpty else { return 0 }
        let mapping = try VaultReorganizer.moveFilesExact(in: drive, moves: moves)
        pruneEmptyAncestors(of: Set(moves.map(\.from)), in: drive)
        if !mapping.isEmpty {
            SyncLog.append(event: "reconcile", summary: "relocated \(mapping.count) files",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return mapping.count
    }

    /// Apply the plan's copies: bring missing content onto the drive from a verified LOCAL source (an
    /// on-Mac instance whose bytes re-hash to the target). Stream-copies hash-verified + atomically
    /// (`VerifiedCopy`), carries the XMP sidecar, and adds the manifest rows in one write. A copy with
    /// no local source (or an occupied destination) is skipped — never overwritten.
    @discardableResult
    public static func applyCopies(_ copies: [Placement], drive: Vault, localVault: Vault?,
                                   catalog: Catalog, macVaultID: String,
                                   flushEvery: Int = 200) throws -> CopyResult {
        guard !copies.isEmpty, let localVault else { return CopyResult(copied: 0, skipped: copies.count) }
        let fm = FileManager.default
        var pending: [ManifestEntry] = []   // placed on disk, not yet recorded in the manifest
        var copied = 0, skipped = 0
        let recorded = Set(try Manifest.read(from: drive.manifestURL).map(\.path))

        // Record what's been placed so far. Called every `flushEvery` files and on EVERY exit path, so
        // an interrupted run (unplug, quit, thrown error) never leaves verified copies on the drive
        // that the manifest doesn't know about.
        func flush() throws {
            guard !pending.isEmpty else { return }
            var entries = try Manifest.read(from: drive.manifestURL)
            let have = Set(entries.map(\.path))
            entries.append(contentsOf: pending.filter { !have.contains($0.path) })
            try Manifest.write(entries, to: drive.manifestURL)
            pending.removeAll(keepingCapacity: true)
        }
        func record(_ c: Placement, at destURL: URL) {
            let attrs = try? fm.attributesOfItem(atPath: destURL.path)
            let size = (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            pending.append(ManifestEntry(hash: ContentHash(stringValue: c.hash), path: c.path,
                                         size: size, mtime: ISO8601Millis.string(from: mtime)))
            copied += 1
        }

        do {
            for c in copies {
                try autoreleasepool {
                    let destURL = drive.absoluteURL(forRelativePath: c.path)
                    if recorded.contains(c.path) { skipped += 1; return }   // already mirrored
                    if fm.fileExists(atPath: destURL.path) {
                        // Already on disk but not in the manifest (e.g. a previous run was interrupted
                        // before it could record it). If the bytes are exactly what we want there, adopt
                        // it into the manifest; anything else is left untouched (never overwritten).
                        if (try? ContentHash.ofFile(at: destURL).stringValue) == c.hash {
                            record(c, at: destURL)
                        } else {
                            skipped += 1
                        }
                        return
                    }
                    // `VerifiedCopy` hashes the stream and refuses a mismatch, so the source needs no
                    // separate pre-hash (that was a second full read of every file). Try each local
                    // instance of the content until one copies clean.
                    var placedFrom: URL?
                    for rel in try catalog.instanceRelPaths(vaultID: localVault.id, hash: c.hash) {
                        let srcURL = localVault.absoluteURL(forRelativePath: rel)
                        guard fm.fileExists(atPath: srcURL.path) else { continue }
                        if VerifiedCopy.copy(from: srcURL, to: destURL, expectedHash: c.hash) == .copied {
                            placedFrom = srcURL
                            break
                        }
                    }
                    guard let srcURL = placedFrom else { skipped += 1; return }
                    // Sidecar (human metadata) travels with the media.
                    let srcSidecar = localVault.sidecarURL(forMediaAt: srcURL)
                    if fm.fileExists(atPath: srcSidecar.path),
                       let sidecarHash = try? ContentHash.ofFile(at: srcSidecar).stringValue {
                        // Best-effort here; `applySidecarUpdates` (end of every reconcile) repairs a
                        // sidecar that failed to land.
                        VerifiedCopy.copy(from: srcSidecar, to: drive.sidecarURL(forMediaAt: destURL),
                                          expectedHash: sidecarHash)
                    }
                    record(c, at: destURL)
                    if pending.count >= flushEvery { try flush() }
                }
            }
        } catch {
            try? flush()
            throw error
        }
        try flush()
        if copied > 0 {
            SyncLog.append(event: "reconcile", summary: "copied \(copied) files onto drive",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return CopyResult(copied: copied, skipped: skipped)
    }

    /// Mirror human-metadata edits onto the drive: for every local photo the drive already holds at its
    /// mirrored path, make the drive's XMP sidecar byte-identical to the Mac's when they differ (or the
    /// drive has none). One-way (Mac → drive), atomic, and never touches media. Without this step a
    /// rating/caption/tag/face edit made AFTER a photo was first mirrored never reached the drive via
    /// reconcile (sidecars only travelled alongside a newly copied file).
    ///
    /// Cheap on a no-change connect: one `stat` per local sidecar + one on the drive; file contents are
    /// read only when size differs or the Mac's sidecar is newer than the drive's.
    @discardableResult
    public static func applySidecarUpdates(drive: Vault, localVault: Vault?, catalog: Catalog,
                                           macVaultID: String) throws -> Int {
        guard let localVault else { return 0 }
        let fm = FileManager.default
        let onDrive = Set(try Manifest.read(from: drive.manifestURL).map(\.path))
        var updated = 0
        for (_, rel) in try catalog.instanceHashPaths(vaultID: localVault.id) {
            autoreleasepool {
                let srcMedia = localVault.absoluteURL(forRelativePath: rel)
                let srcSidecar = localVault.sidecarURL(forMediaAt: srcMedia)
                guard let sAttrs = try? fm.attributesOfItem(atPath: srcSidecar.path) else { return }
                let drivePath = SyncEngine.driveRelPath(forSourceVault: localVault, relPath: rel)
                guard onDrive.contains(drivePath) else { return }   // media not mirrored there (yet)
                let dstSidecar = drive.sidecarURL(forMediaAt: drive.absoluteURL(forRelativePath: drivePath))
                if let dAttrs = try? fm.attributesOfItem(atPath: dstSidecar.path),
                   let sSize = sAttrs[.size] as? NSNumber, let dSize = dAttrs[.size] as? NSNumber,
                   sSize == dSize,
                   let sM = sAttrs[.modificationDate] as? Date, let dM = dAttrs[.modificationDate] as? Date,
                   dM >= sM {
                    return   // same size and the drive's copy is at least as new → already mirrored
                }
                guard let data = try? Data(contentsOf: srcSidecar), !data.isEmpty else { return }
                if (try? Data(contentsOf: dstSidecar)) == data { return }
                if (try? AtomicFile.write(data, to: dstSidecar)) != nil { updated += 1 }
            }
        }
        if updated > 0 {
            SyncLog.append(event: "reconcile", summary: "updated \(updated) sidecars on drive",
                           counterparty: macVaultID, to: drive.syncLogURL)
        }
        return updated
    }

    /// Remove husk directories the removals emptied, deepest-first. `deleteEmptyFolder` refuses any dir
    /// still holding media (ignoring `.openphoto`/dotfiles), so a shared ancestor like the library root
    /// is never touched — only genuinely-empty leftovers are cleaned.
    private static func pruneEmptyAncestors(of paths: Set<String>, in drive: Vault) {
        var dirs = Set<String>()
        for p in paths {
            var dir = (p as NSString).deletingLastPathComponent
            while !dir.isEmpty { dirs.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        for d in dirs.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            try? VaultReorganizer.deleteEmptyFolder(in: drive, relPath: d)
        }
    }

    /// True iff a byte-verified copy of `hash` physically exists at a path NOT being removed — a local
    /// instance (ground truth) or another drive path. Same proof the folder cleaner uses.
    private static func survivorExists(hash: String, excluding removing: Set<String>, drive: Vault,
                                       localVault: Vault?, catalog: Catalog) throws -> Bool {
        let fm = FileManager.default
        if let lv = localVault {
            for rel in try catalog.instanceRelPaths(vaultID: lv.id, hash: hash) {
                let url = lv.absoluteURL(forRelativePath: rel)
                if fm.fileExists(atPath: url.path),
                   (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
            }
        }
        for p in try catalog.vaultPresenceDriveRelPaths(vaultID: drive.id, hash: hash) where !removing.contains(p) {
            let url = drive.absoluteURL(forRelativePath: p)
            if fm.fileExists(atPath: url.path),
               (try? ContentHash.ofFile(at: url).stringValue) == hash { return true }
        }
        return false
    }
}
