import Foundation

/// Place filter: restrict to a whole country (by ISO countryCode) or a specific city within one.
public enum PlaceFilter: Sendable, Equatable {
    case country(String)                          // countryCode
    case city(countryCode: String, city: String)
}

/// Structured (click-to-narrow) filters. person live (4.3); place live (4.4).
public struct SearchFilters: Sendable, Equatable {
    public var dateRange: ClosedRange<Date>?
    public var camera: String?
    public var minRating: Int?       // nil/0 = any
    public var favoritesOnly: Bool
    public var videoOnly: Bool
    public var tags: [String]        // AND: an asset must carry every tag
    public var person: Int64?        // nil = any person
    public var place: PlaceFilter?   // nil = anywhere
    public init(dateRange: ClosedRange<Date>? = nil, camera: String? = nil, minRating: Int? = nil,
                favoritesOnly: Bool = false, videoOnly: Bool = false, tags: [String] = [],
                person: Int64? = nil, place: PlaceFilter? = nil) {
        self.dateRange = dateRange; self.camera = camera; self.minRating = minRating
        self.favoritesOnly = favoritesOnly; self.videoOnly = videoOnly; self.tags = tags
        self.person = person; self.place = place
    }
    public var isEmpty: Bool {
        dateRange == nil && camera == nil && (minRating ?? 0) == 0
            && !favoritesOnly && !videoOnly && tags.isEmpty && person == nil && place == nil
    }
}

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
