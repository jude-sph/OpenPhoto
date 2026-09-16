import Foundation

/// Aggregate facts the catalog derives for a trip's folders (Catalog+Travels.swift).
public struct TravelStats: Sendable, Equatable {
    public var count: Int
    public var minTakenAtMs: Int64?
    public var maxTakenAtMs: Int64?
    public var earliestHash: String?
    public init(count: Int, minTakenAtMs: Int64?, maxTakenAtMs: Int64?, earliestHash: String?) {
        self.count = count; self.minTakenAtMs = minTakenAtMs; self.maxTakenAtMs = maxTakenAtMs
        self.earliestHash = earliestHash
    }
}

/// A trip as the resolver sees it: either a stored record or a folder discovered under the
/// Travels folder (no file yet). `id` of a discovered trip is "folder:<path>" and is never persisted.
public struct TravelDefinition: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case record(TravelRecord)
        case discovered(String)
    }
    public var id: String
    public var source: Source
    public var folders: [String]
    public init(id: String, source: Source, folders: [String]) {
        self.id = id; self.source = source; self.folders = folders
    }
    public var record: TravelRecord? { if case .record(let r) = source { return r }; return nil }
    public var isDiscovered: Bool { record == nil }
}

/// What the UI shows for a trip: the record's decisions merged over the derived facts.
public struct TravelSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var definition: TravelDefinition
    public var name: String
    public var folders: [String]
    public var startDate: String?
    public var endDate: String?
    public var datesOverridden: Bool
    public var places: [TravelPlace]
    public var placesOverridden: Bool
    public var count: Int
    public var coverHash: String?
    public var coverOverridden: Bool

    public var year: Int? { startDate.flatMap { Int($0.prefix(4)) } }
    public var country: String? { places.first?.country }
}

public enum TravelResolver {
    public static let discoveredIDPrefix = "folder:"

    /// Drop duplicates and any path equal to or nested inside another; keep first-seen order.
    public static func normalise(folders: [String]) -> [String] {
        var out: [String] = []
        for f in folders {
            if out.contains(where: { $0 == f || f.hasPrefix($0 + "/") }) { continue }
            out.removeAll { $0.hasPrefix(f + "/") }
            out.append(f)
        }
        return out
    }

    /// Records first (in the given order), then discovered direct subfolders of the Travels folder
    /// (tree order) that are neither hidden nor covered by a record's folder.
    public static func resolve(settings: TravelSettings, records: [TravelRecord],
                               folderTree: [FolderNode]) -> [TravelDefinition] {
        var defs = records.map {
            TravelDefinition(id: $0.id, source: .record($0), folders: normalise(folders: $0.folders))
        }
        guard settings.autoDiscover, let root = settings.travelsFolder else { return defs }
        // "" is the vault root itself: the tree's top-level nodes are its direct children, and no
        // node carries the empty path, so `find` could never return one.
        guard let children = root.isEmpty ? folderTree : find(root, in: folderTree)?.children else { return defs }
        let covered = defs.flatMap(\.folders)
        let hidden = Set(settings.hidden)
        for child in children {
            let p = child.path
            if hidden.contains(p) { continue }
            if covered.contains(where: { p == $0 || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) { continue }
            defs.append(TravelDefinition(id: discoveredIDPrefix + p, source: .discovered(p), folders: [p]))
        }
        return defs
    }

    private static func find(_ path: String, in nodes: [FolderNode]) -> FolderNode? {
        for n in nodes {
            if n.path == path { return n }
            if path.hasPrefix(n.path + "/"), let hit = find(path, in: n.children) { return hit }
        }
        return nil
    }

    /// Merge the record's decisions over the derived facts (nil ⇒ derived; `places == []` ⇒ none).
    public static func summarise(_ def: TravelDefinition, stats: TravelStats,
                                 detectedPlaces: [TravelPlace]) -> TravelSummary {
        let r = def.record
        let derivedStart = stats.minTakenAtMs.map(dateString(fromMs:))
        let derivedEnd = stats.maxTakenAtMs.map(dateString(fromMs:))
        var start = r?.startDate ?? derivedStart
        var end = r?.endDate ?? derivedEnd
        if let s = start, let e = end, s > e { (start, end) = (e, s) }
        return TravelSummary(
            id: def.id, definition: def,
            name: r?.name ?? ((def.folders.first ?? "") as NSString).lastPathComponent,
            folders: def.folders,
            startDate: start, endDate: end,
            datesOverridden: r?.startDate != nil || r?.endDate != nil,
            places: r?.places ?? detectedPlaces, placesOverridden: r?.places != nil,
            count: stats.count,
            coverHash: r?.coverHash ?? stats.earliestHash, coverOverridden: r?.coverHash != nil)
    }

    /// After a folder move/rename `from` → `to`, rewrite every record folder and settings path that is
    /// `from` or lies under it (prefix + "/"), so trips follow their folders. Pure.
    public static func rewritePaths(records: [TravelRecord], settings: TravelSettings, from src: String, to dst: String)
        -> (records: [TravelRecord], settings: TravelSettings, changedRecordIDs: Set<String>) {
        func remap(_ p: String) -> String {
            if p == src { return dst }
            if p.hasPrefix(src + "/") { return dst + String(p.dropFirst(src.count)) }
            return p
        }
        var changed = Set<String>()
        let recs = records.map { r -> TravelRecord in
            var r = r
            let f = r.folders.map(remap)
            if f != r.folders { r.folders = f; changed.insert(r.id) }
            return r
        }
        var s = settings
        s.travelsFolder = s.travelsFolder.map(remap)
        s.hidden = s.hidden.map(remap)
        return (recs, s, changed)
    }

    /// "YYYY-MM-DD" in the local calendar (the same calendar the timeline groups by).
    public static func dateString(fromMs ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Newest start first; undated trips last; ties by name (case-insensitive).
    public static func sorted(_ s: [TravelSummary]) -> [TravelSummary] {
        s.sorted { a, b in
            switch (a.startDate, b.startDate) {
            case let (x?, y?) where x != y: return x > y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
