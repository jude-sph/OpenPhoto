import Foundation

/// Place filter: restrict to a whole country (by ISO countryCode) or a specific city within one.
public enum PlaceFilter: Sendable, Equatable {
    case country(String)                          // countryCode
    case city(countryCode: String, city: String)
}

/// Structured (click-to-narrow) filters. Negatable facets use include/exclude sets:
/// include semantics are per-facet — People/Tags AND (all present), Folders/Places/Cameras OR
/// (any-of); exclude always means "none of these".
public struct SearchFilters: Sendable, Equatable {
    public var includePeople: [Int64] = []
    public var excludePeople: [Int64] = []
    public var includeFolders: [String] = []
    public var excludeFolders: [String] = []
    public var foldersRecursive: Bool = true
    public var includeTags: [String] = []
    public var excludeTags: [String] = []
    public var includePlaces: [PlaceFilter] = []
    public var excludePlaces: [PlaceFilter] = []
    public var includeCameras: [String] = []
    public var excludeCameras: [String] = []
    public var dateRange: ClosedRange<Date>? = nil
    public var minRating: Int? = nil
    public var favoritesOnly: Bool = false
    public var kind: KindFilter? = nil
    public var peoplePresence: PeoplePresence? = nil
    public var hasText: Bool = false

    public init() {}
    public init(includeTags: [String]) { self.includeTags = includeTags }

    public var isEmpty: Bool {
        includePeople.isEmpty && excludePeople.isEmpty
            && includeFolders.isEmpty && excludeFolders.isEmpty
            && includeTags.isEmpty && excludeTags.isEmpty
            && includePlaces.isEmpty && excludePlaces.isEmpty
            && includeCameras.isEmpty && excludeCameras.isEmpty
            && dateRange == nil && (minRating ?? 0) == 0
            && !favoritesOnly && kind == nil && peoplePresence == nil && !hasText
    }
}

public enum KindFilter: String, Sendable, Equatable, CaseIterable { case photo, video, live }
public enum PeoplePresence: Sendable, Equatable { case has, without }

/// Pure combination of the three lanes into one ordered hash list (the unit-tested heart).
public enum SearchRanker {
    public static func combine(structured: [String], text: [String],
                               semantic: [(hash: String, score: Float)], hasText: Bool) -> [String] {
        guard hasText else { return structured }     // empty box → filter set (already date-ordered)
        let allow = Set(structured)
        var out: [String] = []
        var seen = Set<String>()
        for h in text where allow.contains(h) && seen.insert(h).inserted { out.append(h) }
        for (h, _) in semantic where allow.contains(h) && seen.insert(h).inserted { out.append(h) }
        return out
    }
}
