import Foundation
import Accelerate
import simd

/// Pure 2D neighbor-embedding of high-dimensional unit face vectors (UMAP-lite / force-directed).
/// Deterministic for a fixed seed. No I/O, no global state — the single most testable unit.
public enum FaceProjection {
    public struct Params: Sendable {
        public var k: Int = 15            // neighbours per point
        public var epochs: Int = 400
        public var negSamples: Int = 5    // random repulsions per point per epoch
        public var learningRate: Float = 1.0
        public init() {}
    }

    /// Returns 2D coordinates aligned to the input order, centered and scaled into roughly [-1, 1].
    public static func project(_ vectors: [[Float]], seed: UInt64, params: Params = Params()) -> [SIMD2<Float>] {
        let n = vectors.count
        if n == 0 { return [] }
        if n == 1 { return [SIMD2(0, 0)] }
        let dim = vectors[0].count
        guard dim > 0 else { return Array(repeating: SIMD2(0,0), count: n) }

        // Row-normalized contiguous matrix X (n × dim).
        var X = [Float](repeating: 0, count: n * dim)
        for i in 0..<n {
            let v = vectors[i]
            var nrm: Float = 0; vDSP_svesq(v, 1, &nrm, vDSP_Length(min(dim, v.count))); nrm = nrm.squareRoot()
            let inv = nrm > 0 ? 1/nrm : 0
            for j in 0..<min(dim, v.count) { X[i*dim + j] = v[j] * inv }
        }

        // --- chunked cosine kNN (cosine == dot for unit rows) ---
        // For each row block B, S = X_B (B×dim) · Xᵀ (dim×n) via cblas_sgemm; keep top-k per row.
        var nbr = [[Int32]](repeating: [], count: n)
        let block = 256
        var s = SeededRNG(seed: seed)
        X.withUnsafeBufferPointer { xb in
            let xp = xb.baseAddress!
            var start = 0
            while start < n {
                let rows = min(block, n - start)
                var S = [Float](repeating: 0, count: rows * n)
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                            Int32(rows), Int32(n), Int32(dim),
                            1, xp + start*dim, Int32(dim), xp, Int32(dim),
                            0, &S, Int32(n))
                for r in 0..<rows {
                    let gi = start + r
                    // top-k by similarity, excluding self
                    var best: [(Int32, Float)] = []
                    let rowBase = r * n
                    for j in 0..<n where j != gi {
                        let sim = S[rowBase + j]
                        if best.count < params.k { best.append((Int32(j), sim)); if best.count == params.k { best.sort { $0.1 < $1.1 } } }
                        else if sim > best[0].1 { best[0] = (Int32(j), sim); best.sort { $0.1 < $1.1 } }
                    }
                    nbr[gi] = best.map { $0.0 }
                }
                start += rows
            }
        }

        // --- seeded random init in a small box ---
        var Y = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0..<n { Y[i] = SIMD2(s.nextUnit() * 0.2, s.nextUnit() * 0.2) }

        // --- UMAP-style SGD: attract kNN neighbours, repel random negative samples ---
        // a/b shape the smooth attraction curve (≈ min_dist 0.1, spread 1). Crucially the repulsion
        // blows up at short range (the `0.001 + dist2` denominator), so neighbours settle a small
        // distance APART rather than collapsing onto one point. The previous bounded spring had no
        // short-range repulsion, so every cluster imploded to a single coincident dot.
        let a: Float = 1.5769, b: Float = 0.8951
        @inline(__always) func clamp4(_ v: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(max(-4, min(4, v.x)), max(-4, min(4, v.y)))
        }
        // Gradients are accumulated over the whole epoch and applied as one small step — stable across
        // library sizes and validated to spread real data (a per-sample variant under-spread tight clusters).
        let stepScale: Float = 0.04
        var grad = [SIMD2<Float>](repeating: .zero, count: n)
        for epoch in 0..<params.epochs {
            let alpha = params.learningRate * (1 - Float(epoch) / Float(params.epochs))
            for i in 0..<n { grad[i] = .zero }
            for i in 0..<n {
                let yi = Y[i]
                for jb in nbr[i] {                               // attraction (symmetric)
                    let j = Int(jb)
                    let d = yi - Y[j]
                    let dist2 = simd_length_squared(d)
                    guard dist2 > 0 else { continue }
                    let co = (-2 * a * b * powf(dist2, b - 1)) / (1 + a * powf(dist2, b))
                    let g = clamp4(d * co)
                    grad[i] += g
                    grad[j] -= g
                }
                for _ in 0..<params.negSamples {                 // repulsion
                    let k = Int(s.next() % UInt64(n))
                    if k == i { continue }
                    let d = yi - Y[k]
                    let dist2 = simd_length_squared(d)
                    if dist2 > 0 {
                        let co = (2 * b) / ((0.001 + dist2) * (1 + a * powf(dist2, b)))
                        grad[i] += clamp4(d * co)
                    } else {
                        grad[i] += SIMD2(0.5, 0)                 // nudge exactly-coincident points apart
                    }
                }
            }
            let step = alpha * stepScale
            for i in 0..<n { Y[i] += grad[i] * step }
        }

        // --- normalize: center, scale by 98th-percentile radius into ~[-1,1] ---
        var mean = SIMD2<Float>(0,0); for p in Y { mean += p }; mean /= Float(n); for i in 0..<n { Y[i] -= mean }
        var radii = Y.map { simd_length($0) }.sorted()
        let r = max(radii[Int(Float(n) * 0.98)], 1e-4)
        for i in 0..<n { Y[i] /= r }
        return Y
    }
}

/// Tiny deterministic RNG (SplitMix64) so projections are reproducible without Date/Math.random.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Float { Float(next() >> 40) / Float(1 << 24) * 2 - 1 } // [-1,1]
}
