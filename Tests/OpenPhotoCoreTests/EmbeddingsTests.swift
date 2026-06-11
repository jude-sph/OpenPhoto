import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String, takenAtMs: Int64 = 1) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

@Test func embeddingRoundTripsWithinFloat16Tolerance() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let v: [Float] = [0.5, -0.5, 0.5, -0.5]   // already unit-norm
    try cat.upsertEmbedding(hash: A, model: "m1", dim: 4, vector: v)
    let got = try #require(cat.embedding(forHash: A))
    #expect(got.model == "m1" && got.dim == 4)
    for (a, b) in zip(got.vector, v) { #expect(abs(a - b) < 0.001) }   // fp16 tolerance
    #expect(cat.embedding(forHash: B) == nil)
}

@Test func upsertEmbeddingReplaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsertEmbedding(hash: A, model: "m1", dim: 2, vector: [1, 0])
    try cat.upsertEmbedding(hash: A, model: "m1", dim: 2, vector: [0, 1])
    let got = try #require(cat.embedding(forHash: A))
    #expect(abs(got.vector[0]) < 0.001 && abs(got.vector[1] - 1) < 0.001)
    #expect(try cat.embeddingCount() == 1)   // replaced, not duplicated
}

@Test func reconcileDropsOtherModelRowsAndTheirEmbedJobs() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    try cat.upsertEmbedding(hash: A, model: "old", dim: 2, vector: [1, 0])
    try cat.markDerived(hash: A, stage: "embed")
    try cat.upsertEmbedding(hash: B, model: "new", dim: 2, vector: [0, 1])
    try cat.markDerived(hash: B, stage: "embed")

    try cat.reconcileEmbeddingModel(current: "new")
    #expect(cat.embedding(forHash: A) == nil)            // old-model row dropped
    #expect(cat.embedding(forHash: B) != nil)            // current-model row kept
    // A's embed job was cleared → A is pending "embed" again; B is still done.
    #expect(try cat.pendingDerivation(stage: "embed") == [A])
}

@Test func embedStageEligibility() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    #expect(try cat.pendingDerivation(stage: "embed") == [A])   // photos are embed-eligible
}
