import Testing
@testable import OpenPhotoCore

@Test func clustersThreeClearGroups() {
    let items: [(id: Int64, vector: [Float])] = [
        (1, [1, 0, 0]), (2, [0.99, 0.01, 0]),     // group A (≈ +x)
        (3, [0, 1, 0]), (4, [0.02, 0.98, 0]),     // group B (≈ +y)
        (5, [0, 0, 1]),                            // group C (≈ +z), singleton
    ]
    let clusters = FaceClusterer.cluster(items, threshold: 0.2)
    let sets = Set(clusters.map { Set($0) })
    #expect(sets == Set([Set([1, 2]), Set([3, 4]), Set([5])]))
}

@Test func mergesAtLooseThresholdSplitsAtTight() {
    let items: [(id: Int64, vector: [Float])] = [(1, [1, 0]), (2, [0.7, 0.7]), (3, [0, 1])]
    #expect(FaceClusterer.cluster(items, threshold: 0.05).count == 3)  // tight → 3 singletons
    #expect(FaceClusterer.cluster(items, threshold: 0.9).count == 1)   // loose → all one
}

@Test func emptyInputYieldsNoClusters() {
    #expect(FaceClusterer.cluster([], threshold: 0.3).isEmpty)
}

@Test func ignoresMismatchedDimensionVectors() {
    // A stray different-dim vector must not crash the cosine math; it groups alone or is dropped.
    let items: [(id: Int64, vector: [Float])] = [(1, [1, 0]), (2, [0.99, 0.01]), (3, [1, 0, 0])]
    let clusters = FaceClusterer.cluster(items, threshold: 0.2)
    #expect(Set(clusters.flatMap { $0 }).isSuperset(of: [1, 2]))   // the 2-D pair groups; no crash
}
