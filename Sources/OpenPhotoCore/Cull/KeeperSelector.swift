import Foundation

public enum CullMode: Sendable, Equatable { case bursts, duplicates }

/// Pick the suggested keeper for a redundant group and the rejects to pre-select for deletion.
/// Duplicates → highest resolution then largest file; bursts → sharpest then resolution.
/// Favorites & rated photos are NEVER in `evict` (protected — kept, the user can still delete by hand).
public enum KeeperSelector {
    public struct Candidate: Sendable, Equatable {
        public let hash: String
        public let pixelCount: Int
        public let fileSize: Int64
        public let favorite: Bool
        public let rating: Int
        public let sharpness: Double?
        public init(hash: String, pixelCount: Int, fileSize: Int64, favorite: Bool, rating: Int, sharpness: Double?) {
            self.hash = hash; self.pixelCount = pixelCount; self.fileSize = fileSize
            self.favorite = favorite; self.rating = rating; self.sharpness = sharpness
        }
    }

    /// `c` must be non-empty.
    public static func suggestion(_ c: [Candidate], mode: CullMode) -> (keep: String, evict: [String]) {
        precondition(!c.isEmpty)
        let keep: Candidate = c.max { a, b in
            switch mode {
            case .duplicates:
                if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
                if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
                return a.hash > b.hash
            case .bursts:
                let sa = a.sharpness ?? -1, sb = b.sharpness ?? -1
                if sa != sb { return sa < sb }
                if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
                return a.hash > b.hash
            }
        }!
        let evict = c.filter { $0.hash != keep.hash && !$0.favorite && $0.rating == 0 }.map { $0.hash }
        return (keep.hash, evict)
    }
}
