import Foundation

/// Group photos into bursts: sort by capture time, then chain consecutive photos while the gap to
/// the previous ≤ windowMs AND their CLIP cosine ≥ threshold. Vectors are L2-normalized, so cosine
/// is a dot product. Returns groups of ≥ 2 (singletons dropped). Pure + unit-tested.
public enum BurstGrouper {
    public static func group(_ items: [(hash: String, takenAtMs: Int64, vector: [Float])],
                             windowMs: Int64, cosineThreshold: Float) -> [[String]] {
        let sorted = items.sorted { $0.takenAtMs < $1.takenAtMs }
        var groups: [[String]] = []
        var current: [Int] = []
        func flush() { if current.count >= 2 { groups.append(current.map { sorted[$0].hash }) }; current = [] }
        for i in sorted.indices {
            if current.isEmpty { current = [i]; continue }
            let last = current[current.count - 1]
            let gap = sorted[i].takenAtMs - sorted[last].takenAtMs
            if gap <= windowMs && dot(sorted[i].vector, sorted[last].vector) >= cosineThreshold {
                current.append(i)
            } else {
                flush(); current = [i]
            }
        }
        flush()
        return groups
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0; for i in a.indices { s += a[i] * b[i] }; return s
    }
}
