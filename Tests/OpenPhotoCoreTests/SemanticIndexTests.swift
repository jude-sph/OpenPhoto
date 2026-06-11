import Testing
import Foundation
@testable import OpenPhotoCore

@Test func semanticIndexReturnsNearestFirst() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    // Three unit vectors in 2-D at distinct angles.
    try cat.upsertEmbedding(hash: "x", model: "m", dim: 2, vector: [1, 0])
    try cat.upsertEmbedding(hash: "y", model: "m", dim: 2, vector: [0, 1])
    try cat.upsertEmbedding(hash: "z", model: "m", dim: 2, vector: [0.7071, 0.7071])
    let idx = try SemanticIndex(catalog: cat, model: "m")
    let hits = idx.query([1, 0], topN: 2)             // closest to x, then z
    #expect(hits.map(\.hash) == ["x", "z"])
}
