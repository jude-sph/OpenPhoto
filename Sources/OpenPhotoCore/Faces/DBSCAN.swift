import Foundation

/// Density-based clustering (DBSCAN) over face-identity embeddings using cosine distance.
///
/// **Why this and not the old single-link agglomerative clusterer:** single-link joins a face to a
/// cluster if it is near *any* one member, so one bridging face transitively chains two different
/// identities together — the failure that produced a single 1700-photo "person" of unrelated people.
/// DBSCAN instead requires a *dense neighbourhood* (≥ `minPts` faces within `eps`) before a cluster
/// can grow through a point, so a lone bridge can't fuse two identities. Sparse faces with too few
/// neighbours are labelled **noise** (`-1`) and left unclustered rather than forced into a blob.
///
/// Pure, dependency-free, deterministic ⇒ unit-testable with synthetic vectors (no Vision/Core ML,
/// no real face data). Vectors of differing dimensionality are never neighbours (distance = ∞), so a
/// mixed-dimension input never crashes and never wrongly merges across embedding-model versions.
///
/// Complexity: O(n²) neighbour scan. The clusterer only ever runs over the *unassigned* face set
/// (bounded, and shrinking as the user names people), so quadratic is fine here.
public enum DBSCAN {

    /// Per-item cluster label, in input order. Labels are `0…k-1` for clusters and `-1` for noise.
    /// - `eps`: maximum cosine distance (1 − cosine similarity) for two faces to be neighbours.
    /// - `minPts`: neighbours (including the point itself) required for a point to be a *core* point.
    public static func label(_ vectors: [[Float]], eps: Double, minPts: Int) -> [Int] {
        let n = vectors.count
        guard n > 0 else { return [] }

        // L2-normalize once; after that cosine distance = 1 − dot. Zero vectors stay zero (they
        // never come within eps of anything, so they fall out as noise).
        let units: [[Float]] = vectors.map { v in
            let norm = l2norm(v)
            return norm > 0 ? v.map { $0 / norm } : v
        }

        let unvisited = -2, noise = -1
        var labels = [Int](repeating: unvisited, count: n)
        var clusterID = 0

        for p in 0..<n where labels[p] == unvisited {
            let neighbours = region(p, units, eps: eps)
            if neighbours.count < minPts {
                labels[p] = noise                    // (may be reclaimed below as a border point)
                continue
            }
            labels[p] = clusterID
            // Grow the cluster. `seeds` is a worklist of points to expand from, kept sorted and
            // processed in ascending index order so the result is independent of discovery order.
            var seeds = neighbours.filter { $0 != p }
            var inSeeds = Set(seeds)
            var qi = 0
            while qi < seeds.count {
                let q = seeds[qi]; qi += 1
                if labels[q] == noise { labels[q] = clusterID }      // border point joins a cluster
                guard labels[q] == unvisited else { continue }
                labels[q] = clusterID
                let qNeighbours = region(q, units, eps: eps)
                if qNeighbours.count >= minPts {                     // q is itself a core point → expand
                    for r in qNeighbours where !inSeeds.contains(r) {
                        seeds.append(r); inSeeds.insert(r)
                    }
                }
            }
            clusterID += 1
        }
        return labels
    }

    /// Group `(id, vector)` items into clusters of ids, **noise excluded**. Clusters are ordered
    /// largest-first with a smallest-member-id tiebreak, and ids within a cluster are ascending —
    /// fully deterministic regardless of input order.
    public static func groups(_ items: [(id: Int64, vector: [Float])],
                              eps: Double, minPts: Int) -> [[Int64]] {
        let labels = label(items.map(\.vector), eps: eps, minPts: minPts)
        var buckets: [Int: [Int64]] = [:]
        for (i, lbl) in labels.enumerated() where lbl >= 0 {
            buckets[lbl, default: []].append(items[i].id)
        }
        return buckets.values
            .map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                                           : ($0.first ?? .max) < ($1.first ?? .max) }
    }

    // MARK: - Private

    /// Indices within `eps` cosine distance of point `p` (includes `p` itself).
    private static func region(_ p: Int, _ units: [[Float]], eps: Double) -> [Int] {
        let a = units[p]
        var out: [Int] = []
        for j in units.indices where cosineDistance(a, units[j]) <= eps { out.append(j) }
        return out
    }

    private static func l2norm(_ v: [Float]) -> Float {
        var s: Float = 0; for x in v { s += x * x }; return s.squareRoot()
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return .infinity }
        var dot: Float = 0; for k in a.indices { dot += a[k] * b[k] }
        return 1.0 - min(1.0, max(-1.0, Double(dot)))
    }
}
