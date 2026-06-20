import Foundation

/// Pure identity-geometry analyses over per-person centroids and per-person faces.
/// All inputs are L2-normalized vectors; similarity is cosine == dot.
public enum FaceResemblance {
    public struct Lookalike: Sendable, Equatable { public let personID: Int64; public let sim: Float; public let mutual: Bool }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count); var s: Float = 0; for i in 0..<n { s += a[i]*b[i] }; return s
    }

    /// Top-k nearest OTHER person per person, with a `mutual` flag (A→B and B→A).
    public static func lookalikes(centroids: [Int64: [Float]], topK: Int) -> [Int64: [Lookalike]] {
        let ids = Array(centroids.keys)
        var nearest: [Int64: [(Int64, Float)]] = [:]
        for a in ids {
            let ca = centroids[a]!
            let scored = ids.filter { $0 != a }.map { ($0, dot(ca, centroids[$0]!)) }.sorted { $0.1 > $1.1 }
            nearest[a] = Array(scored.prefix(topK))
        }
        var out: [Int64: [Lookalike]] = [:]
        for a in ids {
            out[a] = nearest[a]!.map { (b, sim) in
                let mutual = nearest[b]?.first?.0 == a && nearest[a]?.first?.0 == b
                return Lookalike(personID: b, sim: sim, mutual: mutual)
            }
        }
        return out
    }

    public struct Typicality: Sendable, Equatable { public let medoid: Int64?; public let outliers: [Int64] }

    /// Face nearest the centroid (most typical) and the `outlierCount` farthest (least typical).
    public static func typicality(centroid: [Float], faces: [(id: Int64, vector: [Float])], outlierCount: Int) -> Typicality {
        guard !faces.isEmpty else { return Typicality(medoid: nil, outliers: []) }
        let scored = faces.map { ($0.id, dot(centroid, $0.vector)) }
        let medoid = scored.max { $0.1 < $1.1 }!.0
        let outliers = scored.sorted { $0.1 < $1.1 }.prefix(outlierCount).map { $0.0 }
        return Typicality(medoid: medoid, outliers: Array(outliers))
    }

    /// Shortest resemblance path over the person kNN graph (edge weight = 1 - sim), returned only if
    /// it is a "good path": node count in [minNodes, maxNodes] and every edge sim ≥ minEdgeSim.
    public static func resemblancePath(centroids: [Int64: [Float]], from: Int64, to: Int64,
                                       k: Int, minEdgeSim: Float, minNodes: Int, maxNodes: Int) -> [Int64]? {
        guard from != to, centroids[from] != nil, centroids[to] != nil else { return nil }
        let ids = Array(centroids.keys)
        // kNN adjacency with the min-similarity gate baked in (weak edges don't exist).
        var adj: [Int64: [(Int64, Float)]] = [:]
        for a in ids {
            let ca = centroids[a]!
            let near = ids.filter { $0 != a }.map { ($0, dot(ca, centroids[$0]!)) }
                .sorted { $0.1 > $1.1 }.prefix(k).filter { $0.1 >= minEdgeSim }
            adj[a] = Array(near)
        }
        // Dijkstra on weight = 1 - sim.
        var dist: [Int64: Float] = [from: 0]; var prev: [Int64: Int64] = [:]
        var visited = Set<Int64>(); var frontier: [Int64] = [from]
        while !frontier.isEmpty {
            frontier.sort { (dist[$0] ?? .infinity) < (dist[$1] ?? .infinity) }
            let uId = frontier.removeFirst()
            if visited.contains(uId) { continue }; visited.insert(uId)
            if uId == to { break }
            for (v, sim) in adj[uId] ?? [] {
                let nd = (dist[uId] ?? .infinity) + (1 - sim)
                if nd < (dist[v] ?? .infinity) { dist[v] = nd; prev[v] = uId; frontier.append(v) }
            }
        }
        guard dist[to] != nil else { return nil }
        var path = [to]; while path.last != from { guard let p = prev[path.last!] else { return nil }; path.append(p) }
        path.reverse()
        guard path.count >= minNodes, path.count <= maxNodes else { return nil }
        return path
    }
}
