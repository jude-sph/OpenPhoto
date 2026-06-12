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

    private let library: LibraryService
    private let registry: ImportRegistry

    public init(library: LibraryService, registry: ImportRegistry) {
        self.library = library
        self.registry = registry
    }

    public func run(source: any ImportSource, items: [ImportItem],
                    vault: Vault, dirPath: String,
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

        // 3. Per-item: fetch → hash → destination-aware dedup-check → remember staged file.
        var staged: [(item: ImportItem, url: URL, hash: String)] = []
        for (i, item) in work.enumerated() {
            progress?(Progress(stage: .fetching, done: i, total: work.count, currentName: item.name))
            let takenStr = item.takenAt.map(ISO8601Millis.string(from:)) ?? ""
            let dest = staging.appendingPathComponent(UUID().uuidString + "-" + item.name)
            do {
                try await source.fetch(item, to: dest)
                let hash = try ContentHash.ofFile(at: dest).stringValue
                // Destination-aware dedup: the same source photo CAN be imported into a
                // different folder (creates a second instance); only skip if THIS folder
                // already holds these exact bytes (true no-op).
                if (try? library.catalog.hashPresent(
                        inVault: vault.descriptor.vaultID,
                        dirPath: dirPath,
                        hash: hash)) == true {
                    try? registry.append(.init(sourceKey: source.sourceKey, name: item.name,
                        size: item.byteSize, takenAt: takenStr, hash: hash,
                        importedAt: ISO8601Millis.string(from: Date()),
                        importedTo: "\(dirPath)/\(item.name)"))
                    result.skipped.append(item)
                    try? fm.removeItem(at: dest)
                    continue
                }
                staged.append((item, dest, hash))
            } catch {
                result.failed.append(FailedItem(item: item, reason: String(describing: error)))
            }
        }

        // 4. Place with collision-safe names.
        let dirURL = vault.absoluteURL(forRelativePath: dirPath)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        var placed: [(item: ImportItem, relPath: String, hash: String)] = []
        for (i, s) in staged.enumerated() {
            progress?(Progress(stage: .placing, done: i, total: staged.count, currentName: s.item.name))
            let target = FileNaming.collisionFreeURL(for: s.item.name, in: dirURL)
            do {
                try fm.moveItem(at: s.url, to: target)
                placed.append((s.item, vault.relativePath(of: target), s.hash))
            } catch {
                result.failed.append(FailedItem(item: s.item, reason: String(describing: error)))
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
        for p in placed {
            if manifestByPath[p.relPath] == p.hash {
                try? registry.append(.init(sourceKey: source.sourceKey, name: p.item.name,
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

        library.appendSyncLog(vault: vault, event: "import",
            summary: "\(result.imported.count) imported, \(result.skipped.count) skipped, \(result.failed.count) failed → \(dirPath)",
            counterpartyKey: source.sourceKey)
        return result
    }

}
