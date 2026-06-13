import Testing
import Foundation
@testable import OpenPhotoCore

/// Unit vector at `deg` degrees on the unit circle. Cosine distance between two such vectors is
/// 1 − cos(Δdeg), so geometry maps cleanly onto the clusterer's cosine metric — no real face data.
private func v(_ deg: Double) -> [Float] {
    let r = deg * .pi / 180
    return [Float(cos(r)), Float(sin(r))]
}

@Test func dbscanSeparatesTwoTightClustersWithNoNoise() {
    // Two dense groups 90° apart; every within-group pair is a neighbour, cross-group pairs are not.
    var items: [(id: Int64, vector: [Float])] = []
    for (i, d) in [0.0, 1, 2, 3, 4].enumerated() { items.append((Int64(i), v(d))) }
    for (i, d) in [90.0, 91, 92, 93, 94].enumerated() { items.append((Int64(100 + i), v(d))) }

    let groups = DBSCAN.groups(items, eps: 0.02, minPts: 3)
    #expect(groups.count == 2)
    #expect(groups.map(\.count).sorted() == [5, 5])
    #expect(groups.flatMap { $0 }.count == 10)   // nothing dropped as noise
}

/// The headline property: a dense bridge that makes single-link collapse two identities into one
/// blob does NOT fuse them under DBSCAN, because the bridge points are never *core* points.
@Test func dbscanResistsChainingThatSingleLinkFallsFor() {
    let aIDs: Set<Int64> = [0, 1, 2, 3, 4, 5]
    let bIDs: Set<Int64> = [200, 201, 202, 203, 204, 205]
    // Input order = incremental absorption (cluster A, then the bridge, then cluster B) — the order
    // in which single-link's greedy "append to the first near cluster" chains A→bridge→B into ONE
    // blob. DBSCAN is order-independent (see dbscanIsOrderIndependent), so its result is unaffected.
    var items: [(id: Int64, vector: [Float])] = []
    for (i, d) in [0.0, 1, 2, 3, 4, 5].enumerated() { items.append((Int64(i), v(d))) }
    // Thin chain A→B: consecutive points are within eps (single-link connects straight through),
    // but each chain point has too few neighbours to be a DBSCAN core (minPts = 5).
    for (i, d) in stride(from: 15.0, through: 85.0, by: 10).enumerated() {
        items.append((Int64(100 + i), v(d)))
    }
    for (i, d) in [90.0, 91, 92, 93, 94, 95].enumerated() { items.append((Int64(200 + i), v(d))) }

    let eps = 0.02
    let singleLink = FaceClusterer.cluster(items, threshold: eps)   // the OLD algorithm
    let dbscan = DBSCAN.groups(items, eps: eps, minPts: 5)          // the replacement

    #expect(singleLink.count == 1)                                 // single-link chains into ONE blob
    #expect(dbscan.count >= 2)                                     // DBSCAN keeps the identities apart
    // No DBSCAN cluster mixes an A-core id with a B-core id — the bridge never fuses them.
    for g in dbscan {
        let set = Set(g)
        #expect(!(set.contains(where: aIDs.contains) && set.contains(where: bIDs.contains)))
    }
}

@Test func dbscanLabelsSparseOutliersAsNoise() {
    var items: [(id: Int64, vector: [Float])] = []
    for (i, d) in [0.0, 1, 2, 3, 4].enumerated() { items.append((Int64(i), v(d))) }
    items.append((900, v(40)))    // lone outlier, far from the cluster and from each other
    items.append((901, v(220)))

    let groups = DBSCAN.groups(items, eps: 0.02, minPts: 3)
    #expect(groups.count == 1)
    #expect(groups[0].count == 5)
    #expect(!groups.flatMap { $0 }.contains(900))
    #expect(!groups.flatMap { $0 }.contains(901))
}

@Test func dbscanIsOrderIndependent() {
    var items: [(id: Int64, vector: [Float])] = []
    for (i, d) in [0.0, 1, 2, 3, 4].enumerated() { items.append((Int64(i), v(d))) }
    for (i, d) in [90.0, 91, 92, 93, 94].enumerated() { items.append((Int64(100 + i), v(d))) }

    let forward = DBSCAN.groups(items, eps: 0.02, minPts: 3)
    let reversed = DBSCAN.groups(items.reversed(), eps: 0.02, minPts: 3)
    #expect(forward == reversed)   // deterministic regardless of input order
}

@Test func dbscanNeverMergesAcrossDimensionsOrCrashes() {
    var items: [(id: Int64, vector: [Float])] = []
    for (i, d) in [0.0, 1, 2, 3, 4].enumerated() { items.append((Int64(i), v(d))) }
    items.append((777, [0.1, 0.2, 0.3]))   // a stray 3-d vector among 2-d ones

    let groups = DBSCAN.groups(items, eps: 0.02, minPts: 3)
    #expect(groups.count == 1)                       // the 2-d cluster survives
    #expect(!groups.flatMap { $0 }.contains(777))    // the odd-dim vector is noise, never merged
}
