import Foundation

/// Pure cosine-distance agglomerative clustering of face feature-print vectors (the unit-tested
/// heart — no Vision/Core ML dependency). VNGenerateImageFeaturePrint vectors are NOT normalized
/// and vary in magnitude, so we use COSINE distance (direction only) rather than raw L2.
///
/// **Distance metric:** cosine distance = 1 − cosine_similarity. Each vector is L2-normalized
/// once up front; after normalization, cosine distance = 1 − dot product.
///
/// **Default threshold:** 0.4 (i.e. cosine similarity ≥ 0.6) is a reasonable starting point for
/// VNGenerateImageFeaturePrint face crops — tight enough to avoid merging different people, loose
/// enough to tolerate lighting and pose variation within the same person. This default is surfaced
/// in the app via `AppState.faceClusterThreshold` and can be adjusted by a future UI control.
///
/// **Algorithm:** greedy single-link agglomerative. Walk items in input order; for each item, find
/// the first existing cluster whose nearest member is within `threshold` (single-link), and join
/// it; otherwise start a new singleton cluster. O(n·k) for n faces, k current clusters — fine for
/// the unassigned set (bounded and shrinking as the user names people). Deterministic ⇒ testable.
public enum FaceClusterer {

    /// Greedy single-link agglomerative grouping. `threshold` = max cosine distance (1 − cos sim)
    /// for two faces to share a cluster. Clusters ordered largest-first; each cluster ordered by
    /// input order. Singletons are 1-element clusters. Deterministic.
    ///
    /// Vectors of differing dimensionality are never merged (cross-dim cosine distance = ∞) — they
    /// each start their own cluster, or join a same-dim cluster, so the function never crashes on a
    /// mixed-dim input.
    public static func cluster(_ items: [(id: Int64, vector: [Float])],
                               threshold: Double) -> [[Int64]] {
        guard !items.isEmpty else { return [] }

        // Normalize every vector once. Zero-magnitude vectors stay as-is (they'll never match any
        // other with cosine < infinity, since normalization is undefined; a zero vector never joins).
        let normalized: [(id: Int64, v: [Float], dim: Int)] = items.map { item in
            let n = l2norm(item.vector)
            let unit: [Float] = n > 0 ? item.vector.map { $0 / n } : item.vector
            return (item.id, unit, item.vector.count)
        }

        // Cluster indices — each inner array holds indices into `normalized`.
        var clusters: [[Int]] = []

        for i in normalized.indices {
            var bestCluster = -1
            for (ci, members) in clusters.enumerated() {
                // Single-link: join if ANY member of the cluster is within threshold.
                let anyNear = members.contains { j in
                    cosineDistance(normalized[i], normalized[j]) <= threshold
                }
                if anyNear {
                    bestCluster = ci
                    break
                }
            }
            if bestCluster >= 0 {
                clusters[bestCluster].append(i)
            } else {
                clusters.append([i])
            }
        }

        // Map back to ids; sort clusters largest-first with an explicit tiebreaker on the smallest
        // member id so output is fully deterministic regardless of input order or sort algorithm
        // stability (Array.sorted is NOT guaranteed stable).
        return clusters
            .map { idxs in idxs.map { normalized[$0].id } }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.min() ?? Int64.max) < ($1.min() ?? Int64.max)
            }
    }

    // MARK: - Private math

    private static func l2norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return s.squareRoot()
    }

    /// Cosine distance between two already-L2-normalized vectors. Returns `.infinity` if dims differ
    /// so that cross-dim pairs are never considered within-threshold.
    private static func cosineDistance(
        _ a: (id: Int64, v: [Float], dim: Int),
        _ b: (id: Int64, v: [Float], dim: Int)
    ) -> Double {
        guard a.dim == b.dim else { return .infinity }
        var dot: Float = 0
        for k in 0..<a.dim { dot += a.v[k] * b.v[k] }
        // After L2 normalization, dot product == cosine similarity; clamp to [-1, 1] for safety.
        let clamped = min(1.0, max(-1.0, Double(dot)))
        return 1.0 - clamped
    }
}
