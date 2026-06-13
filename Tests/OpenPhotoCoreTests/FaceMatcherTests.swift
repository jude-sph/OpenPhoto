import Testing
import Foundation
@testable import OpenPhotoCore

private func v(_ deg: Double) -> [Float] {
    let r = deg * .pi / 180
    return [Float(cos(r)), Float(sin(r))]
}

@Test func centroidIsDominatedByTheMajority() {
    // 500 faces at 0° + 1 face at 90° → centroid points essentially at 0° (majority wins).
    var vecs = [[Float]](repeating: v(0), count: 500)
    vecs.append(v(90))
    let c = FaceMatcher.centroid(vecs)!
    #expect(c[0] > 0.99)        // ~cos(small angle)
    #expect(c[1] < 0.05)        // the lone outlier barely tilts it
}

@Test func centroidIsNilForEmptyOrAllStragglers() {
    #expect(FaceMatcher.centroid([]) == nil)
    #expect(FaceMatcher.centroid([[]]) == nil)
}

@Test func matchAssignsFacesToNearestPersonWithinThreshold() {
    let centroids: [(personID: Int64, vector: [Float])] = [(1, v(0)), (2, v(90))]
    let faces: [(id: Int64, vector: [Float])] = [
        (10, v(2)), (11, v(358)),   // near person 1 (0°)
        (20, v(88)), (21, v(92)),   // near person 2 (90°)
        (30, v(45)),                // between both, beyond threshold → unmatched
    ]
    // threshold = cosine distance; ~6° ⇒ 1-cos6° ≈ 0.0055. 45° is 1-cos45° ≈ 0.29 ⇒ unmatched.
    let (sugg, unmatched) = FaceMatcher.match(faces: faces, centroids: centroids, threshold: 0.01)

    let byPerson = Dictionary(uniqueKeysWithValues: sugg.map { ($0.personID, Set($0.faceIDs)) })
    #expect(byPerson[1] == [10, 11])
    #expect(byPerson[2] == [20, 21])
    #expect(unmatched.map(\.id) == [30])
}

@Test func matchWithNoPeopleLeavesEverythingUnmatched() {
    let faces: [(id: Int64, vector: [Float])] = [(1, v(0)), (2, v(90))]
    let (sugg, unmatched) = FaceMatcher.match(faces: faces, centroids: [], threshold: 0.5)
    #expect(sugg.isEmpty)
    #expect(unmatched.count == 2)
}

@Test func matchPicksTheCloserOfTwoPeople() {
    let centroids: [(personID: Int64, vector: [Float])] = [(1, v(0)), (2, v(20))]
    // A face at 14° is within threshold of BOTH but closer to person 2 (20°) than person 1 (0°).
    let (sugg, _) = FaceMatcher.match(faces: [(99, v(14))], centroids: centroids, threshold: 0.05)
    #expect(sugg.count == 1)
    #expect(sugg.first?.personID == 2)
}
