import Testing
import Foundation
@testable import OpenPhotoCore

/// The pre-Accelerate DBSCAN (textbook expansion over `[[Float]]` with a scalar dot product), kept
/// verbatim as the reference the vectorised implementation must reproduce label-for-label.
private enum ReferenceDBSCAN {
    static func label(_ vectors: [[Float]], eps: Double, minPts: Int) -> [Int] {
        let n = vectors.count
        guard n > 0 else { return [] }
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
                labels[p] = noise
                continue
            }
            labels[p] = clusterID
            var seeds = neighbours.filter { $0 != p }
            var inSeeds = Set(seeds)
            var qi = 0
            while qi < seeds.count {
                let q = seeds[qi]; qi += 1
                if labels[q] == noise { labels[q] = clusterID }
                guard labels[q] == unvisited else { continue }
                labels[q] = clusterID
                let qNeighbours = region(q, units, eps: eps)
                if qNeighbours.count >= minPts {
                    for r in qNeighbours where !inSeeds.contains(r) {
                        seeds.append(r); inSeeds.insert(r)
                    }
                }
            }
            clusterID += 1
        }
        return labels
    }

    static func groups(_ items: [(id: Int64, vector: [Float])], eps: Double, minPts: Int) -> [[Int64]] {
        groups(items, labels: label(items.map(\.vector), eps: eps, minPts: minPts))
    }

    /// The original `groups` bucketing, applied to already-computed reference labels (the scalar
    /// reference is slow in debug builds, so the tests run it once per case).
    static func groups(_ items: [(id: Int64, vector: [Float])], labels: [Int]) -> [[Int64]] {
        var buckets: [Int: [Int64]] = [:]
        for (i, lbl) in labels.enumerated() where lbl >= 0 {
            buckets[lbl, default: []].append(items[i].id)
        }
        return buckets.values
            .map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count
                                           : ($0.first ?? .max) < ($1.first ?? .max) }
    }

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

/// Deterministic generator (SplitMix64) — no Foundation randomness, so a failure reproduces.
private struct Gen {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Roughly normal(0,1) (sum of 4 uniforms, centred + scaled).
    mutating func gauss() -> Float {
        var s: Float = 0
        for _ in 0..<4 { s += Float(next() >> 40) / Float(1 << 24) }
        return (s - 2) * 1.7320508
    }
}

/// `n` vectors of dimension `d`: `centroids` random directions, each point = its centroid + per-point
/// noise of relative magnitude `spread`, plus a `noiseFraction` of fully random (unclustered) points.
/// Points are interleaved across centroids so cluster numbering depends on real index order.
private func synthetic(n: Int, d: Int, centroids: Int, spread: Float, noiseFraction: Double,
                       seed: UInt64) -> [[Float]] {
    var g = Gen(state: seed)
    let cs: [[Float]] = (0..<centroids).map { _ in
        let v = (0..<d).map { _ in g.gauss() }
        let nrm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return v.map { $0 / nrm }
    }
    let per = spread / Float(d).squareRoot()
    return (0..<n).map { i in
        if Double(g.next() % 10_000) / 10_000 < noiseFraction {
            return (0..<d).map { _ in g.gauss() }
        }
        let c = cs[i % centroids]
        // Unnormalised on purpose (random scale) — DBSCAN must normalise.
        let scale = 0.5 + Float(g.next() % 1000) / 500
        return (0..<d).map { k in (c[k] + g.gauss() * per) * scale }
    }
}

private func expectEquivalent(_ vectors: [[Float]], eps: Double, minPts: Int,
                              _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
    let old = ReferenceDBSCAN.label(vectors, eps: eps, minPts: minPts)
    let new = DBSCAN.label(vectors, eps: eps, minPts: minPts)
    #expect(old == new, comment, sourceLocation: sourceLocation)
    let items = vectors.enumerated().map { (id: Int64($0.offset) * 7 + 3, vector: $0.element) }
    #expect(ReferenceDBSCAN.groups(items, labels: old)
            == DBSCAN.groups(items, eps: eps, minPts: minPts), comment, sourceLocation: sourceLocation)
}

@Test func dbscanMatchesReferenceOnSyntheticFaceLikeData() {
    // Kept small: the scalar reference is slow in a debug build. n = 600 still crosses the 512-row
    // sgemm block boundary.
    let datasets: [(n: Int, c: Int, spread: Float, noise: Double, seed: UInt64)] = [
        (300, 6, 0.6, 0.10, 1), (600, 12, 0.9, 0.20, 2),
    ]
    let params: [(eps: Double, minPts: Int)] = [(0.50, 3), (0.30, 5)]
    for ds in datasets {
        let vectors = synthetic(n: ds.n, d: 512, centroids: ds.c, spread: ds.spread,
                                noiseFraction: ds.noise, seed: ds.seed)
        for p in params {
            expectEquivalent(vectors, eps: p.eps, minPts: p.minPts,
                             "n=\(ds.n) centroids=\(ds.c) eps=\(p.eps) minPts=\(p.minPts)")
        }
    }
}

/// eps placed EXACTLY on real pairwise distances (as the reference computes them), so many pairs sit
/// on the boundary — where BLAS rounding alone would flip neighbour decisions.
@Test func dbscanMatchesReferenceWhenEpsTiesPairDistances() {
    let vectors = synthetic(n: 300, d: 512, centroids: 6, spread: 0.9, noiseFraction: 0.15, seed: 11)
    func unit(_ v: [Float]) -> [Float] {
        var s: Float = 0; for x in v { s += x * x }; let n = s.squareRoot(); return v.map { $0 / n }
    }
    for (i, j) in [(0, 6), (3, 200)] {
        let a = unit(vectors[i]), b = unit(vectors[j])
        var dot: Float = 0; for k in a.indices { dot += a[k] * b[k] }
        let eps = 1.0 - min(1.0, max(-1.0, Double(dot)))
        for minPts in [3] {
            expectEquivalent(vectors, eps: eps, minPts: minPts, "tie eps=\(eps) (pair \(i),\(j)) minPts=\(minPts)")
        }
    }
}

/// Guards against the equivalence test passing vacuously (everything noise, or one blob).
@Test func dbscanSyntheticDataActuallyExercisesClustersBordersAndNoise() {
    let vectors = synthetic(n: 600, d: 512, centroids: 12, spread: 0.9, noiseFraction: 0.20, seed: 2)
    let labels = DBSCAN.label(vectors, eps: 0.50, minPts: 3)
    #expect(Set(labels.filter { $0 >= 0 }).count >= 8)
    #expect(labels.contains(-1))
    #expect(labels.contains { $0 >= 0 })
}

@Test func dbscanMatchesReferenceOnDegenerateInputs() {
    #expect(DBSCAN.label([], eps: 0.5, minPts: 3) == [])
    #expect(DBSCAN.groups([], eps: 0.5, minPts: 3).isEmpty)

    let one: [[Float]] = [[0.3, 0.4, 0.5]]
    for minPts in [0, 1, 2] { expectEquivalent(one, eps: 0.5, minPts: minPts, "one point, minPts \(minPts)") }

    let identical = [[Float]](repeating: [1, 2, 3, 4], count: 40)
    for minPts in [1, 3, 40, 41] {
        expectEquivalent(identical, eps: 0.1, minPts: minPts, "all identical, minPts \(minPts)")
    }

    // Mixed dimensionality, zero-norm and empty vectors, interleaved with two real clusters.
    var mixed: [[Float]] = []
    for i in 0..<30 {
        let t = Float(i) * 0.001
        mixed.append([1, t, 0])                 // dim-3 cluster
        mixed.append([0, 1, t, 0, 0])           // dim-5 cluster (never a neighbour of dim 3)
        if i % 5 == 0 { mixed.append([0, 0, 0]) }      // zero norm
        if i % 7 == 0 { mixed.append([]) }             // empty
        if i % 9 == 0 { mixed.append([Float(i), -1]) } // dim-2 strays
    }
    for (eps, minPts) in [(0.02, 3), (0.5, 3), (1.0, 2), (1.5, 1), (0.02, 0), (2.0, 3)] {
        expectEquivalent(mixed, eps: eps, minPts: minPts, "mixed dims eps=\(eps) minPts=\(minPts)")
    }
}

@Test func dbscanCancellationReturnsEmptyResult() {
    let vectors = synthetic(n: 1500, d: 64, centroids: 5, spread: 0.5, noiseFraction: 0.1, seed: 9)
    // Cancel immediately.
    #expect(DBSCAN.label(vectors, eps: 0.5, minPts: 3, shouldCancel: { true }).isEmpty)
    // Cancel part-way (after the first block): still empty, never a partial labelling.
    nonisolated(unsafe) var polls = 0
    let partial = DBSCAN.label(vectors, eps: 0.5, minPts: 3, shouldCancel: { polls += 1; return polls > 1 })
    #expect(partial.isEmpty)
    #expect(polls == 2)
    let items = vectors.enumerated().map { (id: Int64($0.offset), vector: $0.element) }
    #expect(DBSCAN.groups(items, eps: 0.5, minPts: 3, shouldCancel: { true }).isEmpty)
    // A never-cancelling hook changes nothing.
    #expect(DBSCAN.label(vectors, eps: 0.5, minPts: 3, shouldCancel: { false })
            == DBSCAN.label(vectors, eps: 0.5, minPts: 3))
}

/// Manual benchmark — never runs in the normal suite. Old-vs-new at n = 1,500 (the scalar reference
/// is too slow beyond that in debug), then the new code alone at n = 20,000:
///   OPENPHOTO_DBSCAN_BENCH=1 swift test --filter dbscanBenchmark
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENPHOTO_DBSCAN_BENCH"] != nil))
func dbscanBenchmarkOldVersusNew() {
    let clock = ContinuousClock()
    func data(_ n: Int) -> [[Float]] {
        synthetic(n: n, d: 512, centroids: max(8, n / 60), spread: 0.9, noiseFraction: 0.25, seed: 42)
    }
    let small = data(1500)
    var old: [Int] = [], new: [Int] = []
    let tOld = clock.measure { old = ReferenceDBSCAN.label(small, eps: 0.5, minPts: 3) }
    let tNew = clock.measure { new = DBSCAN.label(small, eps: 0.5, minPts: 3) }
    print("DBSCAN bench n=1500 d=512: old \(tOld)  new \(tNew)")
    #expect(old == new)

    let big = data(20_000)
    var labels: [Int] = []
    let tBig = clock.measure { labels = DBSCAN.label(big, eps: 0.5, minPts: 3) }
    print("DBSCAN bench n=20000 d=512: new \(tBig)  (clusters \(Set(labels.filter { $0 >= 0 }).count), "
          + "noise \(labels.filter { $0 < 0 }.count))")
}
