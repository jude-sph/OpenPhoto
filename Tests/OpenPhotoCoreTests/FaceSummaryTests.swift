import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

private func vec(_ seed: Int) -> [Float] {
    (0..<FaceEmbedder.dimension).map { Float(($0 * 31 + seed * 17) % 97) / 97 - 0.5 }
}

private func expectSame(_ s: FaceSummary, _ r: FaceRow) {
    #expect(s.id == r.id)
    #expect(s.hash == r.hash)
    #expect(s.rect == r.rect)
    #expect(s.confidence == r.confidence)
    #expect(s.source == r.source)
    #expect(s.personID == r.personID)
    #expect(s.quality == r.quality)
    #expect(s.embeddingDim == r.embedding.count)
}

/// The no-blob variants return exactly the rows (and field values) of their full counterparts.
@Test func faceSummariesMirrorFullRowsWithoutEmbeddings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let alice = try cat.createPerson(name: "Alice")
    let ids = try cat.insertFaces([
        FaceRow(id: nil, hash: A, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                embedding: vec(1), confidence: 0.9, source: "auto", personID: nil, quality: 0.7),
        FaceRow(id: nil, hash: A, rect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
                embedding: [], confidence: 0.4, source: "auto", personID: nil, quality: 0),
        FaceRow(id: nil, hash: B, rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                embedding: vec(2), confidence: 0.8, source: "auto", personID: nil, quality: 0.5),
    ])
    try cat.assignFaces([ids[0], ids[2]], to: alice)
    try cat.addManualPersonTag(hash: B, personID: try cat.createPerson(name: "Bob"))

    for id in ids {
        let full = try #require(try cat.face(forID: id))
        expectSame(try #require(try cat.faceSummary(forID: id)), full)
    }
    #expect(try cat.faceSummary(forID: 9999) == nil)

    for hash in [A, B] {
        let full = try cat.faces(forHash: hash).sorted { $0.id! < $1.id! }
        let lite = try cat.faceSummaries(forHash: hash).sorted { $0.id < $1.id }
        #expect(lite.count == full.count && !full.isEmpty)
        for (s, r) in zip(lite, full) { expectSame(s, r) }
    }

    let full = try cat.faces(forPerson: alice).sorted { $0.id! < $1.id! }
    let lite = try cat.faceSummaries(forPerson: alice).sorted { $0.id < $1.id }
    #expect(lite.count == 2 && full.count == 2)
    for (s, r) in zip(lite, full) { expectSame(s, r) }
}

/// Moving the Float16 decode out of the read closure must not change what the embedding queries return.
@Test func embeddingQueriesRoundTripVectorsAfterDecodeMovedOutOfRead() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let p = try cat.createPerson(name: "P")
    let ids = try cat.insertFaces((0..<6).map {
        FaceRow(id: nil, hash: $0 % 2 == 0 ? A : B, rect: CGRect(x: 0.1 * Double($0), y: 0, width: 0.05, height: 0.05),
                embedding: vec($0), confidence: 0.9, source: "auto", personID: nil)
    })
    try cat.assignFaces([ids[4], ids[5]], to: p)

    // Float16 storage is lossy, so compare against a pack→unpack round trip of the input.
    func stored(_ i: Int) -> [Float] { Float16Codec.unpack(Float16Codec.pack(vec(i)), dim: FaceEmbedder.dimension) }

    let un = try cat.unassignedFacesWithEmbeddings().sorted { $0.id < $1.id }
    #expect(un.map(\.id) == Array(ids[0..<4]))
    for (i, f) in un.enumerated() { #expect(f.vector == stored(i)) }

    let assigned = try cat.assignedFacesWithEmbeddings()
    #expect(assigned.count == 2 && assigned.allSatisfy { $0.personID == p })
    #expect(Set(assigned.map(\.vector)) == [stored(4), stored(5)])
}
