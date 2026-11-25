import Foundation
import Accelerate

/// Density-based clustering (DBSCAN) over face-identity embeddings using cosine distance.
///
/// **Why this and not the old single-link agglomerative clusterer:** single-link joins a face to a
/// cluster if it is near *any* one member, so one bridging face transitively chains two different
/// identities together — the failure that produced a single 1700-photo "person" of unrelated people.
/// DBSCAN instead requires a *dense neighbourhood* (≥ `minPts` faces within `eps`) before a cluster
/// can grow through a point, so a lone bridge can't fuse two identities. Sparse faces with too few
/// neighbours are labelled **noise** (`-1`) and left unclustered rather than forced into a blob.
///
/// Pure (Accelerate only), deterministic ⇒ unit-testable with synthetic vectors (no Vision/Core ML,
/// no real face data). Vectors of differing dimensionality are never neighbours (distance = ∞), so a
/// mixed-dimension input never crashes and never wrongly merges across embedding-model versions.
///
/// Complexity: still O(n²·d) arithmetic, but the neighbour search is one `cblas_sgemm` per BLOCK of
/// query rows against a contiguous row-major matrix of unit vectors (vectorised + multithreaded by
/// Accelerate) instead of a scalar `[[Float]]` loop — see `label` for the design and memory bounds.
public enum DBSCAN {

    /// Half-width of the similarity band around `1 − eps` where the BLAS result is not trusted and the
    /// pair is re-checked with the original scalar arithmetic. ~100× sgemm's worst-case rounding for
    /// d = 512 unit vectors; only a sliver of pairs ever falls inside it.
    static let tieBand = 1e-3

    /// Per-item cluster label, in input order. Labels are `0…k-1` for clusters and `-1` for noise.
    /// - `eps`: maximum cosine distance (1 − cosine similarity) for two faces to be neighbours.
    /// - `minPts`: neighbours (including the point itself) required for a point to be a *core* point.
    /// - `shouldCancel`: polled between similarity blocks (every ≤ 512 query rows). When it returns
    ///   true the run is abandoned and the result is **`[]`** — never a partial labelling. For a
    ///   non-empty input an empty result therefore unambiguously means "cancelled".
    ///
    /// **Design (why no neighbour lists, and no per-point `sgemv`).** Classic DBSCAN issues region
    /// queries in cluster-expansion order, which would force either one matrix-vector product per
    /// point (each query re-streams the whole n×d matrix through the cache, where blocked `sgemm`
    /// tiles it) or materialising all n neighbour lists (O(n²) `Int32`s when the library is dominated
    /// by one identity — tens of GB at n = 100k). Neither is needed, because the labelling the
    /// expansion produces is fully determined by three order-independent facts:
    ///   1. a point is *core* iff its own row has ≥ `minPts` neighbours;
    ///   2. clusters are the connected components of core points under the neighbour relation,
    ///      numbered by ascending smallest core index (the outer loop starts a cluster at the first
    ///      unvisited core point and exhausts its component before moving on);
    ///   3. a non-core point joins the lowest-numbered cluster that has a core point among its
    ///      neighbours (clusters complete one at a time, so the first to reach it wins), else noise.
    /// So a single pass over the rows in index order suffices: each row's similarities come from the
    /// current `sgemm` block; a core row is unioned (union-find) with its already-seen core
    /// neighbours — every core pair is thus decided once, by the later row — and a non-core row just
    /// keeps its own (< `minPts` long) neighbour list for step 3. Peak extra memory is the n×d unit
    /// matrix + one ≤ 64 MB similarity block + O(n·minPts) — independent of neighbourhood sizes.
    ///
    /// The result is identical to the textbook expansion for the same input, bit for bit: BLAS sums
    /// dot products in a different order than a scalar loop (and need not be symmetric), so it only
    /// decides pairs that are clearly inside or outside `eps`; any similarity within `tieBand` of the
    /// boundary (or NaN) is re-decided by a scalar dot in the original's summation order.
    public static func label(_ vectors: [[Float]], eps: Double, minPts: Int,
                             shouldCancel: (() -> Bool)? = nil) -> [Int] {
        let n = vectors.count
        guard n > 0 else { return [] }

        // Vectors of different dimensionality are never neighbours, so each dimension is an
        // independent sub-problem sharing only the global index space (the usual case is one group).
        var byDim: [Int: [Int]] = [:]
        for (i, v) in vectors.enumerated() { byDim[v.count, default: []].append(i) }

        var core = [Bool](repeating: false, count: n)
        var parent = [Int32](repeating: 0, count: n)
        for i in 0..<n { parent[i] = Int32(i) }
        var borderNeighbours = [[Int32]](repeating: [], count: n)   // non-core rows only, < minPts each

        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while parent[Int(c)] != r { let nx = parent[Int(c)]; parent[Int(c)] = r; c = nx }
            return r
        }

        // BLAS similarities below `lo` are certainly outside eps and above `hi` certainly inside
        // (sgemm's error on a 512-d unit dot is ~1e-5, far under `tieBand`); in between — or NaN —
        // the pair is re-decided exactly as the original did (scalar Float dot, Double clamp).
        let boundary = 1.0 - eps
        let lo = Float(boundary - tieBand), hi = Float(boundary + tieBand)

        for dim in byDim.keys.sorted() {
            let members = byDim[dim]!                   // ascending global indices
            let m = members.count

            // L2-normalize once into a contiguous m×dim matrix; after that cosine distance = 1 − dot.
            // Zero vectors stay zero (they never come within eps < 1 of anything → noise).
            var X = [Float](repeating: 0, count: max(1, m * dim))
            X.withUnsafeMutableBufferPointer { xb in
                for (row, gi) in members.enumerated() {
                    vectors[gi].withUnsafeBufferPointer { v in
                        var sq: Float = 0
                        for k in 0..<dim { sq += v[k] * v[k] }
                        let norm = sq.squareRoot()
                        let base = row * dim
                        if norm > 0 { for k in 0..<dim { xb[base + k] = v[k] / norm } }
                        else { for k in 0..<dim { xb[base + k] = v[k] } }
                    }
                }
            }

            // Block of query rows sized so the block×m similarity buffer stays ≤ 64 MB, capped at 512
            // rows so cancellation is polled often even on small inputs.
            let block = max(1, min(512, min(m, (64 << 20) / (MemoryLayout<Float>.stride * m))))
            var S = [Float](repeating: 0, count: block * m)
            var scratch: [Int32] = []
            var start = 0
            while start < m {
                if shouldCancel?() == true { return [] }
                let rows = min(block, m - start)
                if dim > 0 {
                    X.withUnsafeBufferPointer { xb in
                        let xp = xb.baseAddress!
                        // S = X[start ..< start+rows] (rows×dim) · Xᵀ (dim×m), as FaceProjection does.
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                    Int32(rows), Int32(m), Int32(dim),
                                    1, xp + start * dim, Int32(dim), xp, Int32(dim),
                                    0, &S, Int32(m))
                    }
                }   // dim == 0: every dot product is 0 — S is already all zeros.
                S.withUnsafeBufferPointer { sb in X.withUnsafeBufferPointer { xb in
                    let xp = xb.baseAddress!
                    for r in 0..<rows {
                        let row = start + r
                        let gi = members[row]
                        let sp = sb.baseAddress! + r * m
                        scratch.removeAll(keepingCapacity: true)
                        for j in 0..<m {
                            let s = sp[j]
                            if s < lo { continue }                      // certainly outside eps
                            if !(s > hi) {                              // near the boundary, or NaN
                                // The original's exact test: sequential Float dot, Double clamp.
                                let a = xp + row * dim, b = xp + j * dim
                                var dot: Float = 0
                                for k in 0..<dim { dot += a[k] * b[k] }
                                if !(1.0 - min(1.0, max(-1.0, Double(dot))) <= eps) { continue }
                            }
                            scratch.append(Int32(j))
                        }
                        if scratch.count >= minPts {
                            core[gi] = true
                            // Union with the core neighbours already processed (earlier rows of this
                            // group); later core neighbours union with us when their row comes up.
                            for j32 in scratch {
                                let j = Int(j32)
                                if j >= row { break }
                                let gj = members[j]
                                if core[gj] {
                                    let a = find(Int32(gi)), b = find(Int32(gj))
                                    if a != b { parent[Int(max(a, b))] = min(a, b) }
                                }
                            }
                        } else if !scratch.isEmpty {
                            borderNeighbours[gi] = scratch.map { Int32(members[Int($0)]) }
                        }
                    }
                } }
                start += rows
            }
        }

        // Number the core components by ascending smallest core index, then attach border points.
        let noise = -1
        var labels = [Int](repeating: noise, count: n)
        var clusterOfRoot: [Int32: Int] = [:]
        for i in 0..<n where core[i] {
            let root = find(Int32(i))
            if let c = clusterOfRoot[root] {
                labels[i] = c
            } else {
                let c = clusterOfRoot.count
                clusterOfRoot[root] = c
                labels[i] = c
            }
        }
        for i in 0..<n where !core[i] {
            var best = noise
            for j in borderNeighbours[i] where core[Int(j)] {
                let c = labels[Int(j)]
                if best == noise || c < best { best = c }
            }
            labels[i] = best
        }
        return labels
    }

    /// Group `(id, vector)` items into clusters of ids, **noise excluded**. Clusters are ordered
    /// largest-first with a smallest-member-id tiebreak, and ids within a cluster are ascending —
    /// fully deterministic regardless of input order. If `shouldCancel` fires (see `label`) the
    /// result is `[]`; a caller that passes it must consult its own cancellation flag before
    /// reading an empty result as "no clusters".
    public static func groups(_ items: [(id: Int64, vector: [Float])],
                              eps: Double, minPts: Int,
                              shouldCancel: (() -> Bool)? = nil) -> [[Int64]] {
        let labels = label(items.map(\.vector), eps: eps, minPts: minPts, shouldCancel: shouldCancel)
        guard labels.count == items.count else { return [] }      // cancelled
        var buckets: [Int: [Int64]] = [:]
        for (i, lbl) in labels.enumerated() where lbl >= 0 {
            buckets[lbl, default: []].append(items[i].id)
        }
        return buckets.values
            .map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                                           : ($0.first ?? .max) < ($1.first ?? .max) }
    }
}
