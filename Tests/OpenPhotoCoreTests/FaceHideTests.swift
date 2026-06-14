import Testing
import Foundation
@testable import OpenPhotoCore

// MARK: - Helpers (mirrors the style in FacesCRUDTests.swift)

private func photo(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

private let H1 = "sha256:" + String(repeating: "1", count: 64)
private let H2 = "sha256:" + String(repeating: "2", count: 64)
private let H3 = "sha256:" + String(repeating: "3", count: 64)
private let H4 = "sha256:" + String(repeating: "4", count: 64)

/// Build a FaceRow padded to the production embedding dimension so the `dim = 512`
/// clusterable filter keeps these synthetic faces.
private func face(_ hash: String, _ vec: [Float], quality: Float = 1) -> FaceRow {
    var v = vec
    if v.count < FaceEmbedder.dimension {
        v += Array(repeating: 0, count: FaceEmbedder.dimension - v.count)
    }
    return FaceRow(id: nil, hash: hash,
                   rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                   embedding: v, confidence: 0.9, source: "auto",
                   personID: nil, quality: quality)
}

// MARK: - Tests

/// Hiding faces removes them from `unassignedAutoFaceIDs` and puts them in `hiddenAutoFaceIDs`.
@Test func hideFacesRemovesThemFromBucket() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1), photo(H2), photo(H3)])

    let ids = try cat.insertFaces([
        face(H1, [1, 0]),   // will be hidden
        face(H2, [0, 1]),   // will be hidden
        face(H3, [0, 0, 1]) // stays visible
    ])
    let (id1, id2, id3) = (ids[0], ids[1], ids[2])

    try cat.setFacesHidden([id1, id2], hidden: true)

    let bucket = try cat.unassignedAutoFaceIDs()
    #expect(!bucket.contains(id1), "hidden face 1 must not appear in bucket")
    #expect(!bucket.contains(id2), "hidden face 2 must not appear in bucket")
    #expect(bucket.contains(id3),  "visible face 3 must remain in bucket")

    let hidden = try cat.hiddenAutoFaceIDs()
    #expect(hidden.contains(id1), "hidden face 1 must appear in hiddenAutoFaceIDs")
    #expect(hidden.contains(id2), "hidden face 2 must appear in hiddenAutoFaceIDs")
    #expect(!hidden.contains(id3), "visible face 3 must NOT appear in hiddenAutoFaceIDs")
}

/// Hidden faces are excluded from the embeddings used for clustering / suggestion.
@Test func hideFacesExcludesFromEmbeddings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1), photo(H2)])

    let ids = try cat.insertFaces([
        face(H1, [1, 0], quality: 1),   // hidden but quality > 0 → must be excluded
        face(H2, [0, 1], quality: 1),   // visible
    ])
    let (id1, id2) = (ids[0], ids[1])

    try cat.setFacesHidden([id1], hidden: true)

    let embeddings = try cat.unassignedFacesWithEmbeddings()
    let embeddingIDs = embeddings.map(\.id)
    #expect(!embeddingIDs.contains(id1), "hidden face must be excluded from embeddings")
    #expect(embeddingIDs.contains(id2),  "visible face must remain in embeddings")
}

/// Gated faces (quality == 0) are excluded from embeddings regardless; hiding them should work
/// without disturbing the quality=0 gate.
@Test func hideGatedFaceStillExcludedFromEmbeddings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1)])

    let ids = try cat.insertFaces([
        face(H1, [1, 0], quality: 0)   // gated face
    ])
    let id1 = ids[0]

    // Hiding a gated face shouldn't crash or surface it somewhere unexpected.
    try cat.setFacesHidden([id1], hidden: true)

    // It was already excluded from embeddings; still excluded.
    #expect(try cat.unassignedFacesWithEmbeddings().isEmpty)
    // It should appear in hiddenAutoFaceIDs (hidden flag is set regardless of quality).
    #expect(try cat.hiddenAutoFaceIDs().contains(id1))
    // Gated+hidden face was already absent from bucket, still absent.
    let bucket = try cat.unassignedAutoFaceIDs()
    #expect(!bucket.contains(id1))
}

/// Un-hiding restores faces to the bucket and removes them from `hiddenAutoFaceIDs`.
@Test func unhideFacesRestoresToBucket() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1), photo(H2)])

    let ids = try cat.insertFaces([face(H1, [1, 0]), face(H2, [0, 1])])
    let (id1, id2) = (ids[0], ids[1])

    // Hide both, then restore id1.
    try cat.setFacesHidden([id1, id2], hidden: true)
    try cat.setFacesHidden([id1], hidden: false)

    let bucket = try cat.unassignedAutoFaceIDs()
    #expect(bucket.contains(id1),  "restored face must be back in bucket")
    #expect(!bucket.contains(id2), "still-hidden face must remain out of bucket")

    let hidden = try cat.hiddenAutoFaceIDs()
    #expect(!hidden.contains(id1), "restored face must leave hiddenAutoFaceIDs")
    #expect(hidden.contains(id2),  "still-hidden face stays in hiddenAutoFaceIDs")
}

/// `setFacesHidden([], hidden: true)` is a no-op — must not throw and must not change anything.
@Test func hideEmptyListIsNoOp() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1)])

    let ids = try cat.insertFaces([face(H1, [1, 0])])
    let id1 = ids[0]

    // Should not throw.
    try cat.setFacesHidden([], hidden: true)
    try cat.setFacesHidden([], hidden: false)

    // Bucket unchanged.
    let bucket = try cat.unassignedAutoFaceIDs()
    #expect(bucket.contains(id1))
    #expect(try cat.hiddenAutoFaceIDs().isEmpty)
}

/// Assigned (confirmed) faces are not affected by hide logic — they are never in the bucket
/// to begin with, and hiding them (if done) should not move them into `hiddenAutoFaceIDs`.
@Test func hideDoesNotAffectAssignedFaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(H1)])

    let ids = try cat.insertFaces([
        FaceRow(id: nil, hash: H1, rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                embedding: Array(repeating: 0, count: FaceEmbedder.dimension),
                confidence: 0.9, source: "confirmed", personID: nil, quality: 1)
    ])
    let id1 = ids[0]

    // Even if we call setFacesHidden on a confirmed face, it should not appear in hiddenAutoFaceIDs
    // (which filters by source = 'auto').
    try cat.setFacesHidden([id1], hidden: true)

    #expect(try cat.hiddenAutoFaceIDs().isEmpty, "confirmed faces must not appear in hiddenAutoFaceIDs")
}
