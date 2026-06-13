import Foundation

/// Matches unassigned faces against named people by comparing each face to a person's **centroid**
/// (the L2-normalized mean of all that person's assigned face vectors). Because the centroid is a
/// mean, the majority dominates — a person with 500 faces is represented by all 500, not by one
/// chosen face. Pure + deterministic ⇒ unit-tested with synthetic vectors (no Vision/Core ML).
public enum FaceMatcher {

    /// The centroid (L2-normalized mean) of a set of face vectors — a person's recognition identity.
    /// Returns nil for an empty set, an all-zero sum, or when no vector matches the leading dimension.
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dim = vectors.first(where: { !$0.isEmpty })?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        var n = 0
        for v in vectors where v.count == dim {           // ignore odd-dimension stragglers
            for i in 0..<dim { sum[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        let norm = (sum.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { $0 / norm }
    }

    /// Assign each face to the nearest person centroid within `threshold` (max cosine distance).
    /// Returns per-person suggested face ids (largest group first, deterministic) and the faces that
    /// matched no person (which then flow to clustering / the Other-faces bucket).
    public static func match(faces: [(id: Int64, vector: [Float])],
                             centroids: [(personID: Int64, vector: [Float])],
                             threshold: Double)
        -> (suggestions: [(personID: Int64, faceIDs: [Int64])],
            unmatched: [(id: Int64, vector: [Float])]) {
        guard !centroids.isEmpty else { return ([], faces) }
        let cs = centroids.map { (pid: $0.personID, v: unit($0.vector)) }

        var byPerson: [Int64: [Int64]] = [:]
        var unmatched: [(id: Int64, vector: [Float])] = []
        for f in faces {
            let fv = unit(f.vector)
            var bestPID: Int64?
            var bestDist = threshold
            for c in cs where c.v.count == fv.count {
                let d = 1.0 - dot(fv, c.v)
                if d <= bestDist { bestDist = d; bestPID = c.pid }
            }
            if let pid = bestPID { byPerson[pid, default: []].append(f.id) }
            else { unmatched.append(f) }
        }
        let suggestions = byPerson
            .map { (personID: $0.key, faceIDs: $0.value.sorted()) }
            .sorted { $0.faceIDs.count != $1.faceIDs.count
                      ? $0.faceIDs.count > $1.faceIDs.count
                      : $0.personID < $1.personID }
        return (suggestions, unmatched)
    }

    // MARK: - Private

    private static func unit(_ v: [Float]) -> [Float] {
        let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return -1 }
        var s: Float = 0; for i in a.indices { s += a[i] * b[i] }
        return Double(s)
    }
}
