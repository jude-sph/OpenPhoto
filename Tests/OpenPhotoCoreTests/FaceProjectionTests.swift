import Testing
import Foundation
import simd
@testable import OpenPhotoCore

private func seededVec(dim: Int, center: Int, jitter: Float, salt: Int) -> [Float] {
    // Deterministic pseudo-random vector clustered around a one-hot-ish "center" direction.
    var v = [Float](repeating: 0, count: dim)
    var s = UInt64(center &* 1000 &+ salt &+ 1)
    func rnd() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 33) / Float(UInt32.max) - 0.5 }
    for i in 0..<dim { v[i] = jitter * rnd() }
    v[center % dim] += 1.0            // identity direction
    v[(center * 7 + 3) % dim] += 0.8
    let n = (v.reduce(0) { $0 + $1*$1 }).squareRoot()
    return n > 0 ? v.map { $0 / n } : v
}

@Test func projectionSeparatesClusters() {
    let dim = 64, perCluster = 40, clusters = 4
    var vecs: [[Float]] = []; var label: [Int] = []
    for c in 0..<clusters {
        for j in 0..<perCluster { vecs.append(seededVec(dim: dim, center: c*11, jitter: 0.15, salt: j)); label.append(c) }
    }
    let pts = FaceProjection.project(vecs, seed: 42)
    #expect(pts.count == vecs.count)

    // Trustworthiness proxy: each point's 6 nearest neighbours in 2D should be MOSTLY same-cluster.
    func knn2DPurity() -> Double {
        var pure = 0, total = 0
        for i in 0..<pts.count {
            let dists = (0..<pts.count).filter { $0 != i }
                .map { (j: $0, d: simd_distance_squared(pts[i], pts[$0])) }
                .sorted { $0.d < $1.d }.prefix(6)
            for n in dists { total += 1; if label[n.j] == label[i] { pure += 1 } }
        }
        return Double(pure) / Double(total)
    }
    #expect(knn2DPurity() > 0.85)   // islands, not soup
}

@Test func projectionIsDeterministic() {
    let vecs = (0..<30).map { seededVec(dim: 32, center: $0 % 3 * 9, jitter: 0.2, salt: $0) }
    let a = FaceProjection.project(vecs, seed: 7)
    let b = FaceProjection.project(vecs, seed: 7)
    #expect(a == b)
}

@Test func projectionHandlesTinyInput() {
    #expect(FaceProjection.project([], seed: 1).isEmpty)
    #expect(FaceProjection.project([[1,0,0]], seed: 1).count == 1)
    #expect(FaceProjection.project([[1,0],[0,1]], seed: 1).count == 2)
}
