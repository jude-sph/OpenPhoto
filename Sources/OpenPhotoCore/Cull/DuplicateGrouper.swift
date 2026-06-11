import Foundation

/// Group the SAME image saved as separate files. Bucket by exact `dirPath` (sibling-safe — never a
/// prefix), then within each folder union photos whose perceptual-hash Hamming distance ≤ threshold.
/// Cross-folder near-matches are assumed intentional and never grouped. Returns groups with ≥ 2
/// distinct hashes. Pure + unit-tested.
public enum DuplicateGrouper {
    public static func group(_ items: [(hash: String, dirPath: String, value: Int64)],
                             hammingThreshold: Int) -> [[String]] {
        var byFolder: [String: [(hash: String, value: Int64)]] = [:]
        for it in items { byFolder[it.dirPath, default: []].append((it.hash, it.value)) }

        var groups: [[String]] = []
        for (_, rows) in byFolder where rows.count >= 2 {
            var parent = Array(rows.indices)
            func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
            func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
            for i in rows.indices {
                for j in (i + 1)..<rows.count where
                    PerceptualHash.hamming(rows[i].value, rows[j].value) <= hammingThreshold {
                    union(i, j)
                }
            }
            var clusters: [Int: [String]] = [:]
            for i in rows.indices { clusters[find(i), default: []].append(rows[i].hash) }
            for (_, hashes) in clusters where Set(hashes).count >= 2 { groups.append(hashes) }
        }
        return groups
    }
}
