import Foundation

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
    private func ingestSidecars(vault: Vault) throws {
        guard let store = sidecarStores[vault.descriptor.vaultID] else { return }
        for entry in try Manifest.read(from: vault.manifestURL) {
            let data = try store.read(forMediaRelPath: entry.path)
            guard data != .empty else { continue }
            let tags = String(data: try JSONEncoder().encode(data.tags), encoding: .utf8) ?? "[]"
            try catalog.updateHumanMetadata(hash: entry.hash.stringValue,
                                            favorite: data.favorite, rating: data.rating,
                                            caption: data.caption, tagsJSON: tags)
        }
    }

    // MARK: Browse

    public func timelineSections() throws -> [TimelineSection] {
        sections(from: try catalog.timelineItems())
    }

    public func items(inDir dir: String) throws -> [TimelineItem] {
        try catalog.items(inDir: dir)
    }

    public func item(hash: String) throws -> TimelineItem? { try catalog.item(hash: hash) }

    public func folderTree() throws -> [FolderNode] {
        let counts = try catalog.folderCounts()
        var byPath: [String: FolderNode] = [:]
        for (path, count) in counts where !path.isEmpty {
            byPath[path] = FolderNode(path: path,
                                      name: (path as NSString).lastPathComponent,
                                      count: count, children: [])
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, byPath[parent] == nil {
                byPath[parent] = FolderNode(path: parent,
                                            name: (parent as NSString).lastPathComponent,
                                            count: counts[parent] ?? 0, children: [])
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var roots: [FolderNode] = []
        for node in byPath.values.sorted(by: { $0.path > $1.path }) {  // deepest first
            let parent = (node.path as NSString).deletingLastPathComponent
            if parent.isEmpty {
                roots.append(node)
            } else {
                byPath[parent]?.children.append(node)
                byPath[parent]?.children.sort { $0.name < $1.name }
            }
        }
        return roots.sorted { $0.name < $1.name }
    }

    private func sections(from items: [TimelineItem]) -> [TimelineSection] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .full; fmt.timeStyle = .none
        var result: [TimelineSection] = []
        var current: (dayMs: Int64, title: String, items: [TimelineItem])?
        for item in items {   // already newest-first
            let day = cal.startOfDay(for: Date(timeIntervalSince1970:
                Double(item.takenAtMs) / 1000))
            let dayMs = Int64(day.timeIntervalSince1970 * 1000)
            if current?.dayMs == dayMs {
                current?.items.append(item)
            } else {
                if let c = current {
                    result.append(TimelineSection(dayStartMs: c.dayMs, title: c.title, items: c.items))
                }
                current = (dayMs, fmt.string(from: day), [item])
            }
        }
        if let c = current {
            result.append(TimelineSection(dayStartMs: c.dayMs, title: c.title, items: c.items))
        }
        return result
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

    // MARK: Delete / restore

    public struct BinEntry: Sendable, Identifiable, Equatable {
        public var id: String { vaultID + "|" + item.path }
        public let vaultID: String
        public let item: BinStore.BinItem
        public let fileURL: URL
    }

    public func delete(_ item: TimelineItem) async throws {
        guard let bin = binStores[item.vaultID] else { return }
        try bin.moveToBin(relPath: item.relPath,
                          hash: ContentHash(stringValue: item.hash), origin: .user)
        // If this is a Live Photo, the paired video goes too.
        if let pairHash = item.livePairHash,
           let pairInstance = try catalog.instanceItem(hash: pairHash, vaultID: item.vaultID) {
            try bin.moveToBin(relPath: pairInstance.relPath,
                              hash: ContentHash(stringValue: pairHash), origin: .user)
        }
        try await rescan(vaultID: item.vaultID)
    }

    public func restore(_ entry: BinEntry) async throws {
        try binStores[entry.vaultID]?.restore(relPath: entry.item.path)
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

    private func rescan(vaultID: String) async throws {
        guard let v = vault(id: vaultID) else { return }
        try await Task.detached(priority: .utility) { [catalog] in
            _ = try await Scanner.scan(vault: v, catalog: catalog)
        }.value
        try ingestSidecars(vault: v)
    }
}
