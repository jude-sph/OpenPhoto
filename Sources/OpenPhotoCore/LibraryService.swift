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
    /// Parsed sidecars by absolute sidecar path, valid while the file's size + mtime are unchanged.
    /// `ingestSidecars` runs after EVERY scan (watcher tick, import batch, folder move) and used to
    /// re-read and re-parse every sidecar in the library each time — ~70% of a rescan on a 25k-photo
    /// library, and the reason a folder move sat on "Indexing library". In-memory only: the first
    /// scan after launch reads them all, later scans stat them and parse only what changed.
    private let sidecarCache = SidecarCache()
    private final class SidecarCache: @unchecked Sendable {
        struct Entry { let size: Int64; let mtimeSec: Int; let mtimeNsec: Int; let data: SidecarData }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func get(_ path: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[path] }
        func set(_ path: String, _ e: Entry?) { lock.lock(); defer { lock.unlock() }; entries[path] = e }
    }

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
            try? catalog.purgePendingDeletionsStillInLibrary()
            try ingestSidecars(vault: v)
        }
    }

    /// Mirror on-disk sidecars into catalog columns (sidecars are authoritative).
    /// A corrupt or unreadable sidecar is silently skipped — the media file is
    /// still valid and the metadata will be empty until the sidecar is repaired.
    private func ingestSidecars(vault: Vault) throws {
        guard let store = sidecarStores[vault.descriptor.vaultID] else { return }
        // Read every sidecar, then apply in ONE write transaction that only touches rows whose
        // values actually differ (was two write transactions per sidecar, on every rescan).
        var batch: [Catalog.SidecarMetadata] = []
        var regions: [String: [FaceRegion]] = [:]
        let encoder = JSONEncoder()
        _ = store
        let root = vault.rootURL.path
        for entry in try Manifest.read(from: vault.manifestURL) {
            // <dir>/.openphoto/<name>.xmp (format §5), built as a plain path: one stat per photo, and
            // a read + parse only when the sidecar is new or its size/mtime changed.
            let rel = entry.path as NSString
            let dir = rel.deletingLastPathComponent
            let path = root + "/" + (dir.isEmpty ? "" : dir + "/") + Vault.stateDirName + "/"
                + rel.lastPathComponent + ".xmp"
            var st = stat()
            guard stat(path, &st) == 0 else { sidecarCache.set(path, nil); continue }   // no sidecar
            let size = Int64(st.st_size), sec = Int(st.st_mtimespec.tv_sec), nsec = Int(st.st_mtimespec.tv_nsec)
            let data: SidecarData
            if let hit = sidecarCache.get(path), hit.size == size, hit.mtimeSec == sec, hit.mtimeNsec == nsec {
                data = hit.data
            } else {
                // A corrupt/unreadable sidecar is skipped (and not cached, so a repair is picked up).
                guard let raw = FileManager.default.contents(atPath: path),
                      let parsed = try? XMP.parse(raw) else { continue }
                sidecarCache.set(path, .init(size: size, mtimeSec: sec, mtimeNsec: nsec, data: parsed))
                data = parsed
            }
            guard data != .empty else { continue }
            let tags = String(data: try encoder.encode(data.tags), encoding: .utf8) ?? "[]"
            batch.append(Catalog.SidecarMetadata(hash: entry.hash.stringValue, favorite: data.favorite,
                                                 rating: data.rating, caption: data.caption,
                                                 tagsJSON: tags, rotation: data.rotation))
            if !data.faces.isEmpty { regions[entry.hash.stringValue, default: []] += data.faces }
        }
        try catalog.applySidecarMetadata(batch)
        // Confirmed people (mwg-rs:Regions) — additive/idempotent, so a rebuilt catalog gets them back.
        try catalog.applySidecarFaceRegions(regions)
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

    public func folderTree(videoOnly: Bool = false) throws -> [FolderNode] {
        var counts = try catalog.folderCounts(videoOnly: videoOnly)
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

    /// Add a keyword tag to each item, MERGING with its existing tags (never replacing) and skipping
    /// items that already carry it. Persists to the XMP sidecar + catalog via `updateMetadata`, so the
    /// tag is durable and searchable like any hand-set tag. Used for auto-tagging (e.g. an import
    /// provenance tag). Other metadata (rating/favorite/caption/faces/rotation) is preserved.
    public func appendTag(_ tag: String, toItems items: [TimelineItem]) throws {
        for item in items {
            var tags = (try? JSONDecoder().decode([String].self,
                                                  from: Data(item.tagsJSON.utf8))) ?? []
            guard !tags.contains(tag) else { continue }
            tags.append(tag)
            try updateMetadata(for: item, rating: item.rating, favorite: item.favorite,
                               caption: item.caption, tags: tags)
        }
    }

    public func updateMetadata(for item: TimelineItem, rating: Int, favorite: Bool,
                               caption: String?, tags: [String]) throws {
        if let store = sidecarStores[item.vaultID] {
            // Read-modify-write so a metadata edit never wipes the sidecar's confirmed faces or rotation.
            let existing = (try? store.read(forMediaRelPath: item.relPath)) ?? .empty
            let data = SidecarData(rating: rating, favorite: favorite, caption: caption, tags: tags,
                                   faces: existing.faces, rotation: existing.rotation)
            try store.write(data, forMediaRelPath: item.relPath)  // durable first
        }
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        try catalog.updateHumanMetadata(hash: item.hash, favorite: favorite,
                                        rating: rating, caption: caption, tagsJSON: tagsJSON)
    }

    /// Set display rotation (0/90/180/270 CW) for the content: read-modify-write every local instance's
    /// sidecar (preserving all other fields) and mirror to the catalog. Display-only — pixels untouched.
    /// Returns the normalized rotation.
    @discardableResult
    public func setRotation(for item: TimelineItem, rotation: Int) throws -> Int {
        let norm = ((rotation % 360) + 360) % 360
        for inst in (try? catalog.instances(forHash: item.hash)) ?? [] {
            guard let store = sidecarStores[inst.vaultID] else { continue }
            let existing = (try? store.read(forMediaRelPath: inst.relPath)) ?? .empty
            let data = SidecarData(rating: existing.rating, favorite: existing.favorite,
                                   caption: existing.caption, tags: existing.tags,
                                   faces: existing.faces, rotation: norm)
            try? store.write(data, forMediaRelPath: inst.relPath)
        }
        try catalog.setRotation(hash: item.hash, rotation: norm)
        return norm
    }

    /// Reconcile an asset's tags with macOS Finder tags on its local files via a 3-way merge against the
    /// stored baseline. Reads the UNION of all local instance files' Finder tags, merges with
    /// `proposedTags` + the baseline, writes the merged set to EVERY local file, and stores the new
    /// baseline. Returns the merged set (the caller persists it to the XMP sidecar + catalog). A
    /// drive-only asset (no reachable local file) returns `proposedTags` unchanged and writes nothing.
    /// The favourite flag is folded in as the reserved `FinderTags.favoriteTagName` tag, so the SAME
    /// 3-way merge governs it: favouriting in the app adds the Finder tag, the Finder tag sets the
    /// favourite, and a removal on either side (relative to the baseline) propagates. On the FIRST
    /// sync the baseline lacks the reserved tag, so an existing app favourite is *added* to Finder,
    /// never cleared. Returns the merged regular tags (reserved stripped) and the merged favourite.
    public func reconcileFinderTags(forHash hash: String, proposedTags: [String],
                                    favorite: Bool) throws -> (tags: [String], favorite: Bool) {
        let fav = FinderTags.favoriteTagName
        let regular = proposedTags.filter { $0.caseInsensitiveCompare(fav) != .orderedSame }
        let urls: [URL] = ((try? catalog.instances(forHash: hash)) ?? []).compactMap { inst in
            guard let v = vault(id: inst.vaultID) else { return nil }
            let u = v.absoluteURL(forRelativePath: inst.relPath)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard !urls.isEmpty else { return (regular, favorite) }
        let finder = Set(urls.flatMap { FinderTags.read($0) })
        let baseline = Set((try? catalog.finderTagBaseline(forHash: hash)) ?? [])
        var openphoto = Set(regular)
        if favorite { openphoto.insert(fav) }
        let merged = TagMerge.merge(baseline: baseline, openphoto: openphoto, finder: finder)
        let mergedArr = merged.sorted()
        // Only advance the baseline if every on-disk write succeeded. If a write failed, the file
        // still carries its old tags; persisting `mergedArr` as the baseline would make the next
        // 3-way merge read that staleness as a deliberate Finder-side removal and delete the tags.
        // Leaving the baseline unchanged makes the next reconcile re-merge from the true disk state.
        var allWritten = true
        for u in urls {
            do { try FinderTags.write(mergedArr, to: u) } catch { allWritten = false }
        }
        if allWritten { try? catalog.setFinderTagBaseline(hash: hash, tags: mergedArr) }
        return (merged.subtracting([fav]).sorted(), merged.contains(fav))
    }

    /// Rename a file on disk (explicit user action). Sidecar moves with it.
    /// The name actually used for a rename: the typed name with the ORIGINAL extension re-attached when
    /// it was dropped or changed (a file without a media extension is skipped by the scanner and would
    /// vanish from the library). Throws for names that are empty, hidden, or contain a path separator.
    public static func sanitizedRename(_ typed: String, original: String) throws -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              name != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        let origExt = (original as NSString).pathExtension
        guard !origExt.isEmpty else { return name }
        if (name as NSString).pathExtension.lowercased() == origExt.lowercased() {
            guard !(name as NSString).deletingPathExtension.isEmpty else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return name
        }
        return name + "." + origExt
    }

    @discardableResult
    public func rename(_ item: TimelineItem, to typedName: String) async throws -> String {
        let newFileName = try Self.sanitizedRename(
            typedName, original: (item.relPath as NSString).lastPathComponent)
        guard let vault = vault(id: item.vaultID) else { return newFileName }
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
        return newFileName
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
        // Resilient: a per-item enqueue or a per-vault rescan failure must not abort the whole
        // batch and (worse) skip the reconciling rescan, which would leave the catalog showing
        // files that are already in the bin. Process every vault, always rescan the ones we
        // touched, and surface the first error only after everything has been attempted.
        var firstError: Error?
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for (vaultID, group) in byVault {
            guard let bin = binStores[vaultID] else { continue }
            // Batched: every primary is moved first and the bin log is rewritten ONCE (then once more
            // for the Live-pair videos, if any) — not one whole-log rewrite + full flush per file.
            // A primary already gone / unreadable is skipped, not counted.
            let failures = bin.moveToBin(group.map {
                BinStore.BinMove(relPath: $0.relPath, hash: ContentHash(stringValue: $0.hash),
                                 origin: .user)
            })
            let binned = group.enumerated().filter { failures[$0.offset] == nil }.map(\.element)
            let n = binned.count
            // Best-effort: each binned still's Live-pair video is binned + queued alongside it.
            var queue: [(hash: String, relPath: String)] = []
            var pairMoves: [BinStore.BinMove] = []
            for item in binned {
                queue.append((item.hash, item.relPath))
                if let pairHash = item.livePairHash,
                   let pairInstance = try? catalog.instanceItem(hash: pairHash, vaultID: vaultID) {
                    pairMoves.append(BinStore.BinMove(relPath: pairInstance.relPath,
                                                      hash: ContentHash(stringValue: pairHash),
                                                      origin: .user))
                    queue.append((pairHash, pairInstance.relPath))
                }
            }
            bin.moveToBin(pairMoves)
            // The files are binned; if recording the pending deletions fails, keep going (the
            // rescan below still reconciles the catalog) but remember the error to report.
            do {
                try catalog.enqueuePendingDeletions(queue, deletedAtMs: nowMs)   // one transaction
            } catch { if firstError == nil { firstError = error } }
            if n > 0 {
                do { try await rescan(vaultID: vaultID); deleted += n }
                catch { if firstError == nil { firstError = error } }
            }
        }
        if let firstError { throw firstError }
        return deleted
    }

    public func restore(_ entry: BinEntry) async throws {
        let outcome = await restoreBatch([entry])
        if let error = outcome.itemErrors.first?.value ?? outcome.otherError { throw error }
    }

    /// Restore a set of bin entries in one pass: every file (and sidecar) is moved back, each
    /// vault's bin log is rewritten ONCE, the pending deletions of every restored hash (and its
    /// Live pair) are dequeued in one transaction, and each touched vault is rescanned ONCE —
    /// instead of a whole-log rewrite + full library rescan per entry. Resilient like `delete`:
    /// an entry whose file can't be restored is skipped (absent from the result) without stopping
    /// the rest, and the touched vaults are always rescanned. Returns the entries actually
    /// restored; throws only a catalog/rescan error, after everything has been attempted.
    @discardableResult
    public func restore(_ entries: [BinEntry]) async throws -> [BinEntry] {
        let outcome = await restoreBatch(entries)
        if let error = outcome.otherError { throw error }
        return outcome.restored
    }

    private func restoreBatch(_ entries: [BinEntry]) async
        -> (restored: [BinEntry], itemErrors: [Int: any Error], otherError: (any Error)?) {
        var itemErrors: [Int: any Error] = [:]
        var otherError: (any Error)?
        var restoredIdx: [Int] = []
        var byVault: [String: [Int]] = [:]
        var vaultOrder: [String] = []
        for (i, e) in entries.enumerated() {
            if byVault[e.vaultID] == nil { vaultOrder.append(e.vaultID) }
            byVault[e.vaultID, default: []].append(i)
        }
        var touched: [String] = []
        for vaultID in vaultOrder {
            guard let bin = binStores[vaultID], let idxs = byVault[vaultID] else { continue }
            let failures = bin.restore(relPaths: idxs.map { entries[$0].item.path })
            for (k, i) in idxs.enumerated() {
                if let error = failures[k] { itemErrors[i] = error } else { restoredIdx.append(i) }
            }
            // A file can be back on disk even when its entry reports failure (the log rewrite
            // failed after the move), so rescan whenever anything was attempted.
            touched.append(vaultID)
        }
        restoredIdx.sort()
        let restored = restoredIdx.map { entries[$0] }
        // Dequeue each restored hash, mirrored onto its Live pair (favor not-deleting: a restored
        // still should not leave its video queued to propagate alone).
        do {
            var hashes: [String] = []
            for e in restored {
                hashes.append(e.item.hash)
                if let pair = try catalog.assetLivePairHash(forHash: e.item.hash) { hashes.append(pair) }
            }
            try catalog.dequeuePendingDeletions(hashes: hashes)
        } catch { otherError = error }
        for vaultID in touched {
            do { try await rescan(vaultID: vaultID) }
            catch { if otherError == nil { otherError = error } }
        }
        return (restored, itemErrors, otherError)
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
        try? catalog.purgePendingDeletionsStillInLibrary()
        try ingestSidecars(vault: v)
    }

    /// Append an event to the vault's sync-log.jsonl (format §9, informative).
    public func appendSyncLog(vault: Vault, event: String, summary: String,
                              counterpartyKey: String) {
        SyncLog.append(event: event, summary: summary,
                       counterparty: counterpartyKey, to: vault.syncLogURL)
    }
}
