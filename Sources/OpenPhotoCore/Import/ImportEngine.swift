import Foundation

/// Runs one import batch: stage → hash → dedup → place → rescan → verify →
/// registry. Spec: docs/superpowers/specs/2026-06-08-phase2-import-design.md §3.
public final class ImportEngine: Sendable {
    public struct ImportedItem: Sendable, Equatable {
        public let item: ImportItem
        public let hash: String
        public let placedRelPath: String
    }
    public struct FailedItem: Sendable {
        public let item: ImportItem
        public let reason: String
    }
    public struct BatchResult: Sendable {
        public var imported: [ImportedItem] = []
        public var skipped: [ImportItem] = []      // duplicates (destination-aware)
        public var failed: [FailedItem] = []
    }
    public struct Progress: Sendable {
        public enum Stage: String, Sendable { case fetching, placing, verifying }
        public let stage: Stage
        public let done: Int
        public let total: Int
        public let currentName: String
    }

    /// Result of one item's fetch → hash → dedup, produced concurrently in Stage 2.
    private enum Stage2Outcome: Sendable {
        case staged(item: ImportItem, url: URL, hash: String)
        case skipped(item: ImportItem, entry: ImportRegistry.Entry)
        case failed(item: ImportItem, reason: String)
    }

    private let library: LibraryService
    private let registry: ImportRegistry

    public init(library: LibraryService, registry: ImportRegistry) {
        self.library = library
        self.registry = registry
    }

    /// Fetch one item into staging, hash it, and run the destination-aware dedup check.
    /// Pure w.r.t. shared state: returns an outcome; the caller serially folds outcomes and
    /// batches registry writes. Each call hashes its own file (ContentHash drains a per-chunk
    /// autorelease pool internally, so concurrent hashing stays memory-bounded).
    private static func fetchHashDedup(item: ImportItem, source: any ImportSource,
                                       sourceKey: String, staging: URL,
                                       library: LibraryService, vaultID: String,
                                       destDir: String) async -> Stage2Outcome {
        let fm = FileManager.default
        let takenStr = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
        let dest = staging.appendingPathComponent(UUID().uuidString + "-" + item.name)
        do {
            try await source.fetch(item, to: dest)
            let hash = try ContentHash.ofFile(at: dest).stringValue
            if (try? library.catalog.hashPresent(
                    inVault: vaultID, dirPath: destDir, hash: hash)) == true {
                try? fm.removeItem(at: dest)
                let e = ImportRegistry.Entry(sourceKey: sourceKey, name: item.name,
                    size: item.byteSize, takenAt: takenStr, hash: hash,
                    importedAt: ISO8601Millis.string(from: Date()),
                    importedTo: "\(destDir)/\(item.name)")
                return .skipped(item: item, entry: e)
            }
            return .staged(item: item, url: dest, hash: hash)
        } catch {
            return .failed(item: item, reason: String(describing: error))
        }
    }

    public func run(source: any ImportSource, items: [ImportItem],
                    vault: Vault, dirPath: String,
                    subdirForItem: (@Sendable (ImportItem) -> String)? = nil,
                    postPlace: (@Sendable (ImportedItem) async -> Void)? = nil,
                    progress: (@Sendable (Progress) -> Void)? = nil) async -> BatchResult {
        var result = BatchResult()
        let fm = FileManager.default

        // 0. Expand Live pairs: selecting either half imports both (spec §3).
        var work = items
        let ids = Set(items.map(\.id))
        let missingPartnerIDs = items.compactMap { item in
            item.livePartnerID.flatMap { ids.contains($0) ? nil : $0 }
        }
        if !missingPartnerIDs.isEmpty {
            let all = (try? await source.enumerateItems()) ?? []
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            for pid in missingPartnerIDs {
                if let partner = byID[pid] { work.append(partner) }
            }
        }

        // 1. Fresh staging area (cleared at session start by the UI; per-batch uuid here).
        let staging = vault.stateDirURL.appendingPathComponent("staging")
            .appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 2. Disk-space precheck over all work items.
        let needed = work.reduce(Int64(0)) { $0 + $1.byteSize }
        if let free = (try? vault.rootURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage,
           free < needed * 2 {   // ×2: staging + placed copies coexist briefly
            result.failed = work.map { FailedItem(item: $0, reason: "not enough disk space") }
            return result
        }

        // Per-item destination dir: dirPath plus the optional per-item subdir (foreign-vault
        // imports preserve THEIR folder tree under the chosen parent). Empty subdir = flat.
        func destDir(for item: ImportItem) -> String {
            guard let sub = subdirForItem?(item), !sub.isEmpty else { return dirPath }
            return dirPath.isEmpty ? sub : dirPath + "/" + sub
        }

        // 3. Per-item fetch → hash → dedup, bounded-concurrent (width ≤ 6 to balance CPU-bound
        //    hashing against single-device source I/O). Outcomes are folded in deterministic
        //    index order so placement + progress stay stable regardless of completion order.
        //    Destination-aware dedup: the same source photo CAN be imported into a different
        //    folder (creates a second instance); only skip if THIS folder already holds the bytes.
        let width = min(6, ProcessInfo.processInfo.activeProcessorCount)
        let vaultID = vault.descriptor.vaultID
        let srcKey = source.sourceKey
        let lib = library            // local binding so the task closure captures no `self`
        var outcomes = [Stage2Outcome?](repeating: nil, count: work.count)
        await withTaskGroup(of: (Int, Stage2Outcome).self) { group in
            var next = 0, done = 0
            func addTask(_ i: Int) {
                let item = work[i]
                let dDir = destDir(for: item)
                group.addTask {
                    (i, await Self.fetchHashDedup(item: item, source: source, sourceKey: srcKey,
                        staging: staging, library: lib, vaultID: vaultID, destDir: dDir))
                }
            }
            while next < min(width, work.count) { addTask(next); next += 1 }
            for await (i, outcome) in group {
                outcomes[i] = outcome
                done += 1
                progress?(Progress(stage: .fetching, done: done, total: work.count,
                                   currentName: work[i].name))
                if next < work.count { addTask(next); next += 1 }
            }
        }

        var staged: [(item: ImportItem, url: URL, hash: String)] = []
        var skipEntries: [ImportRegistry.Entry] = []
        for outcome in outcomes {
            switch outcome {
            case .staged(let item, let url, let hash): staged.append((item, url, hash))
            case .skipped(let item, let entry): result.skipped.append(item); skipEntries.append(entry)
            case .failed(let item, let reason): result.failed.append(FailedItem(item: item, reason: reason))
            case .none: break   // every index is filled by the group above
            }
        }
        try? registry.appendBatch(skipEntries)

        // 4. Place with collision-safe names (per-item destination dir).
        var placed: [(item: ImportItem, relPath: String, hash: String)] = []
        for (i, s) in staged.enumerated() {
            progress?(Progress(stage: .placing, done: i, total: staged.count, currentName: s.item.name))
            let dirURL = vault.absoluteURL(forRelativePath: destDir(for: s.item))
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let target = FileNaming.collisionFreeURL(for: s.item.name, in: dirURL)
            do {
                try fm.moveItem(at: s.url, to: target)
                placed.append((s.item, vault.relativePath(of: target), s.hash))
            } catch {
                result.failed.append(FailedItem(item: s.item, reason: String(describing: error)))
            }
        }

        // 4.5. Post-place hook (e.g. sidecar carry) — BEFORE the rescan so whatever it
        // writes is ingested by the same scan.
        if let postPlace {
            for p in placed {
                await postPlace(ImportedItem(item: p.item, hash: p.hash, placedRelPath: p.relPath))
            }
        }

        // 5. One incremental rescan picks the placed files into manifest+catalog.
        progress?(Progress(stage: .verifying, done: 0, total: placed.count, currentName: ""))
        do { try await library.rescan(vaultID: vault.descriptor.vaultID) }
        catch {
            result.failed.append(contentsOf: placed.map {
                FailedItem(item: $0.item, reason: "rescan failed (files are placed and will be adopted by the next scan): \(error)") })
            return result
        }

        // 6. Verify: manifest hash (scanner's independent computation) must
        //    equal the staging hash. Only verified items enter the registry.
        let manifestByPath = Dictionary(uniqueKeysWithValues:
            ((try? Manifest.read(from: vault.manifestURL)) ?? []).map { ($0.path, $0.hash.stringValue) })
        var importEntries: [ImportRegistry.Entry] = []
        for p in placed {
            if manifestByPath[p.relPath] == p.hash {
                importEntries.append(.init(sourceKey: source.sourceKey, name: p.item.name,
                    size: p.item.byteSize,
                    takenAt: p.item.takenAt.map(ISO8601Millis.string(from:)) ?? "",
                    hash: p.hash,
                    importedAt: ISO8601Millis.string(from: Date()),
                    importedTo: p.relPath))
                result.imported.append(ImportedItem(item: p.item, hash: p.hash,
                                                    placedRelPath: p.relPath))
            } else {
                result.failed.append(FailedItem(item: p.item,
                    reason: "verification mismatch at \(p.relPath)"))
            }
        }
        try? registry.appendBatch(importEntries)

        library.appendSyncLog(vault: vault, event: "import",
            summary: "\(result.imported.count) imported, \(result.skipped.count) skipped, \(result.failed.count) failed → \(dirPath)",
            counterpartyKey: source.sourceKey)
        return result
    }

}
