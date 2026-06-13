import Foundation

public enum TimelineGrouping: String, CaseIterable, Sendable {
    case day, week, month, year, none
}

public struct TimelineSection: Sendable, Equatable {
    public let dayStartMs: Int64
    public let title: String        // "Friday, June 6" etc.
    public let items: [TimelineItem]
}

public struct FolderNode: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String         // dirPath
    public let name: String
    public let count: Int           // direct items
    public var children: [FolderNode]
}

public final class LibraryService: Sendable {
    public let vaults: [Vault]
    public let catalog: Catalog
    public let thumbnails: ThumbnailStore
    private let sidecarStores: [String: SidecarStore]   // vaultID → store
    private let binStores: [String: BinStore]

    public init(vaultRoots: [URL], appSupportDir: URL) throws {
        var vs: [Vault] = []
        for root in vaultRoots {
            vs.append(try Vault.openOrCreate(at: root, role: .local))
        }
        vaults = vs
        catalog = try Catalog(at: appSupportDir.appendingPathComponent("catalog.sqlite"))
        thumbnails = ThumbnailStore(cacheDir: appSupportDir.appendingPathComponent("thumbs"))
        sidecarStores = Dictionary(uniqueKeysWithValues:
            vs.map { ($0.descriptor.vaultID, SidecarStore(vault: $0)) })
        binStores = Dictionary(uniqueKeysWithValues:
            vs.map { ($0.descriptor.vaultID, BinStore(vault: $0)) })
        for v in vs {
            try catalog.registerVault(id: v.descriptor.vaultID,
                                      role: v.descriptor.role.rawValue,
                                      rootPath: v.rootURL.path)
        }
    }

    public func vault(id: String) -> Vault? { vaults.first { $0.descriptor.vaultID == id } }

    public func absoluteURL(for item: TimelineItem) -> URL? {
        vault(id: item.vaultID)?.absoluteURL(forRelativePath: item.relPath)
    }

    // MARK: Scan

    /// Full scan of all vaults off the calling context; progress via callback.
    public func scanAll(progress: (@Sendable (Scanner.Progress) -> Void)? = nil) async throws {
        for v in vaults {
            let vault = v
            let p = progress
            try await Task.detached(priority: .utility) { [catalog] in
                _ = try await Scanner.scan(vault: vault, catalog: catalog) { p?($0) }
            }.value
            try ingestSidecars(vault: v)
        }
    }

    /// Mirror on-disk sidecars into catalog columns (sidecars are authoritative).
    /// A corrupt or unreadable sidecar is silently skipped — the media file is
    /// still valid and the metadata will be empty until the sidecar is repaired.
    private func ingestSidecars(vault: Vault) throws {
        guard let store = sidecarStores[vault.descriptor.vaultID] else { return }
        for entry in try Manifest.read(from: vault.manifestURL) {
            guard let data = try? store.read(forMediaRelPath: entry.path),
                  data != .empty else { continue }
            let tags = String(data: try JSONEncoder().encode(data.tags), encoding: .utf8) ?? "[]"
            try catalog.updateHumanMetadata(hash: entry.hash.stringValue,
                                            favorite: data.favorite, rating: data.rating,
                                            caption: data.caption, tagsJSON: tags)
        }
    }

    // MARK: Browse

    public func timelineSections() throws -> [TimelineSection] {
        try timelineSections(grouping: .day)
    }

    public func timelineSections(grouping: TimelineGrouping, videoOnly: Bool = false) throws -> [TimelineSection] {
        let items = try catalog.timelineItems(videoOnly: videoOnly)
        switch grouping {
        case .none:
            return items.isEmpty ? [] : [TimelineSection(dayStartMs: 0, title: "All photos", items: items)]
        default:
            return groupedSections(from: items, grouping: grouping)
        }
    }

    private func groupedSections(from items: [TimelineItem], grouping: TimelineGrouping) -> [TimelineSection] {
        let cal = Calendar.current
        let component: Calendar.Component
        let fmt = DateFormatter()
        switch grouping {
        case .week:
            component = .weekOfYear
            fmt.dateStyle = .medium; fmt.timeStyle = .none
        case .month:
            component = .month
            fmt.dateFormat = "MMMM yyyy"
        case .year:
            component = .year
            fmt.dateFormat = "yyyy"
        default:
            component = .day
            fmt.dateStyle = .full; fmt.timeStyle = .none
        }
        var result: [TimelineSection] = []
        var current: (bucketMs: Int64, title: String, items: [TimelineItem])?
        for item in items {
            let date = Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
            guard let intervalStart = cal.dateInterval(of: component, for: date)?.start else { continue }
            let bucketMs = Int64(intervalStart.timeIntervalSince1970 * 1000)
            let title: String
            if grouping == .week {
                title = "Week of \(fmt.string(from: intervalStart))"
            } else {
                title = fmt.string(from: intervalStart)
            }
            if current?.bucketMs == bucketMs {
                current?.items.append(item)
            } else {
                if let c = current {
                    result.append(TimelineSection(dayStartMs: c.bucketMs, title: c.title, items: c.items))
                }
                current = (bucketMs, title, [item])
            }
        }
        if let c = current {
            result.append(TimelineSection(dayStartMs: c.bucketMs, title: c.title, items: c.items))
        }
        return result
    }

    public func items(inDir dir: String, recursive: Bool = false) throws -> [TimelineItem] {
        try catalog.items(inDir: dir, recursive: recursive)
    }

    public func item(hash: String) throws -> TimelineItem? { try catalog.item(hash: hash) }

    /// Return all relative directory paths (non-hidden, non-.openphoto) under `root`.
    private func directoriesUnder(_ root: URL) -> [String] {
        let fm = FileManager.default
        let prefix = root.path + "/"
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var dirs: [String] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if vals?.isDirectory == true {
                // Mirror Scanner's walk: skip the state dir and opaque packages (Apple Photos library
                // etc.) so their internal directories don't surface as empty folders in the tree.
                if url.lastPathComponent == ".openphoto"
                    || url.isOpaqueMediaPackage(isPackage: vals?.isPackage) {
                    en.skipDescendants(); continue
                }
                // Resolve symlinks on the enumerated URL so its path uses the same
                // prefix form as `root.path` (on macOS the enumerator may return
                // /private/var/… while root.path is /var/…).
                let resolved = url.resolvingSymlinksInPath().path
                let rel = resolved.hasPrefix(prefix)
                    ? String(resolved.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
                    : url.lastPathComponent
                if !rel.isEmpty { dirs.append(rel) }
            }
        }
        return dirs
    }

    public func folderTree() throws -> [FolderNode] {
        var counts = try catalog.folderCounts()
        // Union in real filesystem directories from the primary vault (so empty dirs appear).
        if let primaryRoot = vaults.first?.rootURL {
            for dir in directoriesUnder(primaryRoot) where counts[dir] == nil {
                counts[dir] = 0
            }
        }
        // Materialize every path (and intermediate parents) with direct counts.
        var byPath: [String: FolderNode] = [:]
        for (path, count) in counts where !path.isEmpty {
            byPath[path] = FolderNode(path: path,
                                      name: (path as NSString).lastPathComponent,
                                      count: count, children: [])
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if byPath[parent] == nil {
                    byPath[parent] = FolderNode(path: parent,
                                                name: (parent as NSString).lastPathComponent,
                                                count: counts[parent] ?? 0, children: [])
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        // Parent → children relationships, then build the tree recursively so
        // every node carries its children (value-type snapshot bug fixed).
        var childPaths: [String: [String]] = [:]
        var rootPaths: [String] = []
        for path in byPath.keys {
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty { rootPaths.append(path) }
            else { childPaths[parent, default: []].append(path) }
        }
        func build(_ path: String) -> FolderNode {
            var node = byPath[path]!
            node.children = (childPaths[path] ?? []).sorted().map(build)
            return node
        }
        var tree = rootPaths.sorted().map(build)
        // Photos sitting directly in the library root (dirPath "") have no subfolder node, so they'd
        // be invisible in the Folders view. Surface them as a top-level node named after the library
        // folder; selecting it browses the loose root photos via `items(inDir: "")`.
        if let rootCount = counts[""], rootCount > 0, let rootURL = vaults.first?.rootURL {
            tree.insert(FolderNode(path: "", name: rootURL.lastPathComponent,
                                   count: rootCount, children: []), at: 0)
        }
        return tree
    }

    // MARK: Edit

    public func updateMetadata(for item: TimelineItem, rating: Int, favorite: Bool,
                               caption: String?, tags: [String]) throws {
        let data = SidecarData(rating: rating, favorite: favorite, caption: caption, tags: tags)
        try sidecarStores[item.vaultID]?.write(data, forMediaRelPath: item.relPath)  // durable first
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        try catalog.updateHumanMetadata(hash: item.hash, favorite: favorite,
                                        rating: rating, caption: caption, tagsJSON: tagsJSON)
    }

    /// Reconcile an asset's tags with macOS Finder tags on its local files via a 3-way merge against the
    /// stored baseline. Reads the UNION of all local instance files' Finder tags, merges with
    /// `proposedTags` + the baseline, writes the merged set to EVERY local file, and stores the new
    /// baseline. Returns the merged set (the caller persists it to the XMP sidecar + catalog). A
    /// drive-only asset (no reachable local file) returns `proposedTags` unchanged and writes nothing.
    public func reconcileFinderTags(forHash hash: String, proposedTags: [String]) throws -> [String] {
        let urls: [URL] = ((try? catalog.instances(forHash: hash)) ?? []).compactMap { inst in
            guard let v = vault(id: inst.vaultID) else { return nil }
            let u = v.absoluteURL(forRelativePath: inst.relPath)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard !urls.isEmpty else { return proposedTags }
        let finder = Set(urls.flatMap { FinderTags.read($0) })
        let baseline = Set((try? catalog.finderTagBaseline(forHash: hash)) ?? [])
        let merged = TagMerge.merge(baseline: baseline, openphoto: Set(proposedTags), finder: finder)
        let mergedArr = merged.sorted()
        for u in urls { try? FinderTags.write(mergedArr, to: u) }
        try? catalog.setFinderTagBaseline(hash: hash, tags: mergedArr)
        return mergedArr
    }

    /// Rename a file on disk (explicit user action). Sidecar moves with it.
    public func rename(_ item: TimelineItem, to newFileName: String) async throws {
        guard let vault = vault(id: item.vaultID) else { return }
        let oldURL = vault.absoluteURL(forRelativePath: item.relPath)
        let dir = (item.relPath as NSString).deletingLastPathComponent
        let newRel = dir.isEmpty ? newFileName : dir + "/" + newFileName
        let newURL = vault.absoluteURL(forRelativePath: newRel)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let oldSidecar = vault.sidecarURL(forMediaAt: oldURL)
        if FileManager.default.fileExists(atPath: oldSidecar.path) {
            try FileManager.default.moveItem(at: oldSidecar,
                                             to: vault.sidecarURL(forMediaAt: newURL))
        }
        try await rescan(vaultID: item.vaultID)
    }

    // MARK: Delete / restore

    public struct BinEntry: Sendable, Identifiable, Equatable {
        public var id: String { vaultID + "|" + item.path }
        public let vaultID: String
        public let item: BinStore.BinItem
        public let fileURL: URL
    }

    public func delete(_ item: TimelineItem) async throws {
        _ = try await delete([item])
    }

    /// Delete a selection: move each file (and its Live-pair video) into the local bin
    /// (`origin: .user`) AND enqueue a pending deletion so the removal can later be reviewed
    /// for propagation to a drive. Resilient: a file already gone is skipped, not fatal. One
    /// rescan per vault touched. Returns the count actually binned. Unlike `evict`, this records
    /// the intent to remove the photo everywhere; `evict` (which never enqueues) only frees the
    /// local copy of something kept on a drive.
    @discardableResult
    public func delete(_ items: [TimelineItem]) async throws -> Int {
        var byVault: [String: [TimelineItem]] = [:]
        for it in items { byVault[it.vaultID, default: []].append(it) }
        var deleted = 0
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for (vaultID, group) in byVault {
            guard let bin = binStores[vaultID] else { continue }
            var n = 0
            for item in group {
                do {
                    try bin.moveToBin(relPath: item.relPath,
                                      hash: ContentHash(stringValue: item.hash), origin: .user)
                } catch { continue }   // primary already gone / unreadable — skip, not counted
                try catalog.enqueuePendingDeletion(hash: item.hash, relPath: item.relPath, deletedAtMs: nowMs)
                n += 1
                // Best-effort: the Live pair's video is binned + queued alongside it.
                if let pairHash = item.livePairHash,
                   let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                    try? bin.moveToBin(relPath: pairInstance.relPath,
                                       hash: ContentHash(stringValue: pairHash), origin: .user)
                    try? catalog.enqueuePendingDeletion(hash: pairHash, relPath: pairInstance.relPath,
                                                        deletedAtMs: nowMs)
                }
            }
            if n > 0 { try await rescan(vaultID: vaultID); deleted += n }
        }
        return deleted
    }

    public func restore(_ entry: BinEntry) async throws {
        try binStores[entry.vaultID]?.restore(relPath: entry.item.path)
        try catalog.dequeuePendingDeletion(hash: entry.item.hash)
        // Mirror the dequeue onto a Live pair (favor not-deleting: a restored still
        // should not leave its video queued to propagate alone).
        if let pair = try catalog.assetLivePairHash(forHash: entry.item.hash) {
            try catalog.dequeuePendingDeletion(hash: pair)
        }
        try await rescan(vaultID: entry.vaultID)
    }

    public func binItems() throws -> [BinEntry] {
        var out: [BinEntry] = []
        for v in vaults {
            guard let bin = binStores[v.descriptor.vaultID] else { continue }
            for i in try bin.list() {
                out.append(BinEntry(vaultID: v.descriptor.vaultID, item: i,
                                    fileURL: bin.binnedFileURL(relPath: i.path)))
            }
        }
        return out.sorted { $0.item.deletedAt > $1.item.deletedAt }
    }

    public func rescan(vaultID: String) async throws {
        guard let v = vault(id: vaultID) else { return }
        try await Task.detached(priority: .utility) { [catalog] in
            _ = try await Scanner.scan(vault: v, catalog: catalog)
        }.value
        try ingestSidecars(vault: v)
    }

    /// Append an event to the vault's sync-log.jsonl (format §9, informative).
    public func appendSyncLog(vault: Vault, event: String, summary: String,
                              counterpartyKey: String) {
        SyncLog.append(event: event, summary: summary,
                       counterparty: counterpartyKey, to: vault.syncLogURL)
    }
}
