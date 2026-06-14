import Foundation

/// Maps a single user-facing "grouping sensitivity" (0 = Strict … 1 = Loose) to the three DBSCAN /
/// centroid-match knobs the People pipeline uses. The default position `s = 0.5` reproduces the
/// historical hard-coded constants exactly, so a user who never touches the slider sees no change.
public struct FaceClusterParams: Sendable, Equatable {
    /// DBSCAN neighbour distance (cosine). Higher = more permissive grouping.
    public let eps: Double
    /// DBSCAN core-point density. Lower = sparser clusters allowed.
    public let minPts: Int
    /// Max cosine distance to suggest a face as a member of an existing person. Higher = looser.
    public let matchThreshold: Double

    public init(eps: Double, minPts: Int, matchThreshold: Double) {
        self.eps = eps; self.minPts = minPts; self.matchThreshold = matchThreshold
    }

    /// `s` in 0…1 (clamped). Strict (0): eps 0.45 / minPts 4 / match 0.50.
    /// Default (0.5): eps 0.50 / minPts 3 / match 0.55. Loose (1): eps 0.60 / minPts 2 / match 0.60.
    public static func forSensitivity(_ s: Double) -> FaceClusterParams {
        let c = min(max(s, 0), 1)
        // Piecewise-linear with a knee at the default so 0.5 lands exactly on 0.50.
        let eps = c <= 0.5 ? 0.45 + 0.10 * c : 0.50 + 0.20 * (c - 0.5)
        let minPts = min(max(Int((4 - 2 * c).rounded()), 2), 4)
        let matchThreshold = 0.50 + 0.10 * c
        return FaceClusterParams(eps: eps, minPts: minPts, matchThreshold: matchThreshold)
    }
}
