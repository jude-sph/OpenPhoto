import Testing
import Foundation
@testable import OpenPhotoCore

private func u(_ v: [Float]) -> [Float] { let n=(v.reduce(0){$0+$1*$1}).squareRoot(); return n>0 ? v.map{$0/n}:v }

@Test func lookalikesFindsNearestAndMutual() {
    // A,B close; C,D close; A's nearest is B and B's nearest is A → mutual.
    let cents: [Int64: [Float]] = [
        1: u([1, 0.05, 0]), 2: u([0.97, 0.10, 0]),
        3: u([0, 1, 0.05]), 4: u([0.05, 0.95, 0]),
    ]
    let look = FaceResemblance.lookalikes(centroids: cents, topK: 1)
    #expect(look[1]?.first?.personID == 2)
    #expect(look[2]?.first?.personID == 1)
    #expect(look[1]?.first?.mutual == true)
    #expect(look[3]?.first?.personID == 4)
}

@Test func typicalityPicksMedoidAndOutliers() {
    let centroid = u([1,0,0])
    let faces: [(id: Int64, vector: [Float])] = [
        (10, u([1, 0.02, 0])),   // most typical
        (11, u([0.9, 0.2, 0])),
        (12, u([0.2, 0.9, 0])),  // outlier
    ]
    let r = FaceResemblance.typicality(centroid: centroid, faces: faces, outlierCount: 1)
    #expect(r.medoid == 10)
    #expect(r.outliers == [12])
}

@Test func resemblancePathGoodAndBadCases() {
    // chain 1-2-3-4 each adjacent pair similar (~0.9), endpoints dissimilar.
    let cents: [Int64: [Float]] = [
        1: u([1,0,0,0]), 2: u([0.8,0.6,0,0]), 3: u([0,0.8,0.6,0]), 4: u([0,0,0.8,0.6]),
    ]
    // good: 1→4 is 3 hops (4 nodes), every edge strong
    let good = FaceResemblance.resemblancePath(centroids: cents, from: 1, to: 4,
                  k: 3, minEdgeSim: 0.3, minNodes: 3, maxNodes: 6)
    #expect(good == [1,2,3,4])
    // reject single hop (too short): 1→2 directly
    let short = FaceResemblance.resemblancePath(centroids: cents, from: 1, to: 2,
                  k: 3, minEdgeSim: 0.3, minNodes: 3, maxNodes: 6)
    #expect(short == nil)
    // reject when an edge is too weak
    let weak = FaceResemblance.resemblancePath(centroids: cents, from: 1, to: 4,
                  k: 3, minEdgeSim: 0.95, minNodes: 3, maxNodes: 6)
    #expect(weak == nil)
}
