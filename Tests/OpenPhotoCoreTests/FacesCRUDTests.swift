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

private func face(_ hash: String, _ vec: [Float], source: String = "auto",
                  personID: Int64? = nil, conf: Float = 0.9, quality: Float = 1,
                  rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)) -> FaceRow {
    // Pad to the production dimension so the `dim = 512` clusterable filter keeps these synthetic
    // faces (zero-padding preserves dot products / norms among the leading components).
    var v = vec
    if v.count < FaceEmbedder.dimension {
        v += Array(repeating: 0, count: FaceEmbedder.dimension - v.count)
    }
    return FaceRow(id: nil, hash: hash, rect: rect, embedding: v,
                   confidence: conf, source: source, personID: personID, quality: quality)
}

@Test func replaceFacesKeepsConfirmedDropsAuto() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    // Seed one auto + one confirmed face on A.
    let ids = try cat.insertFaces([face(A, [1, 0]), face(A, [0, 1], source: "confirmed")])
    #expect(ids.count == 2)
    // Re-detect → replaceFaces with a fresh auto row at a DIFFERENT location (so the confirmed-overlap
    // guard doesn't drop it — that guard is exercised separately below).
    try cat.replaceFaces(forHash: A, with: [
        face(A, [0.5, 0.5], rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))])
    let rows = try cat.faces(forHash: A)
    #expect(rows.filter { $0.source == "confirmed" }.count == 1)  // confirmed survived
    #expect(rows.filter { $0.source == "auto" }.count == 1)       // old auto replaced by new auto
}

@Test func replaceFacesSkipsAutoOverlappingConfirmed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    _ = try cat.insertFaces([face(A, [0, 1], source: "confirmed",
                                  rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))])
    // Re-detection re-finds the named face (overlapping rect) AND a genuinely new face elsewhere.
    try cat.replaceFaces(forHash: A, with: [
        face(A, [1, 0], rect: CGRect(x: 0.21, y: 0.21, width: 0.3, height: 0.3)),  // overlaps confirmed
        face(A, [0, 0, 1], rect: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)),  // new face
    ])
    let rows = try cat.faces(forHash: A)
    #expect(rows.filter { $0.source == "confirmed" }.count == 1)  // named face untouched, not duplicated
    #expect(rows.filter { $0.source == "auto" }.count == 1)       // only the non-overlapping new auto
}

@Test func unassignedExcludesStaleDimAndGatedFaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    _ = try cat.insertFaces([
        face(A, [1, 0]),                                              // good: dim 512, quality 1
        FaceRow(id: nil, hash: A, rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                embedding: [0.1, 0.2, 0.3], confidence: 0.9, source: "auto",
                personID: nil, quality: 1),                          // stale v1 dim (3) → excluded
        face(A, [0, 1], quality: 0),                                 // gated out (quality 0) → excluded
    ])
    #expect(try cat.unassignedFacesWithEmbeddings().count == 1)
}

@Test func catalogMetaRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    #expect(try cat.meta("faceModelVersion") == nil)
    try cat.setMeta("faceModelVersion", "adaface-ir101-v1")
    #expect(try cat.meta("faceModelVersion") == "adaface-ir101-v1")
    try cat.setMeta("faceModelVersion", "next")              // upsert overwrites
    #expect(try cat.meta("faceModelVersion") == "next")
}

@Test func resetAutoFacesKeepsConfirmed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    _ = try cat.insertFaces([
        face(A, [1, 0]),
        face(A, [0, 1], source: "confirmed", rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))])
    try cat.resetAutoFaces()
    let rows = try cat.faces(forHash: A)
    #expect(rows.count == 1 && rows[0].source == "confirmed")
}

@Test func unassignedFacesRoundTripVectors() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    _ = try cat.insertFaces([face(A, [0.5, -0.5, 0.25])])
    let un = try cat.unassignedFacesWithEmbeddings()
    #expect(un.count == 1)
    for (a, b) in zip(un[0].vector, [0.5, -0.5, 0.25] as [Float]) { #expect(abs(a - b) < 0.001) }
}

@Test func createAssignReassignPeople() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let ids = try cat.insertFaces([face(A, [1, 0]), face(B, [0, 1])])
    let alice = try cat.createPerson(name: "Alice")
    try cat.assignFaces(ids, to: alice)
    #expect(try cat.faces(forPerson: alice).count == 2)
    #expect(try cat.faces(forPerson: alice).allSatisfy { $0.source == "confirmed" })
    #expect(try cat.unassignedFacesWithEmbeddings().isEmpty)
    // Reassign one face off → back to unassigned/auto.
    try cat.reassignFace(ids[0], to: nil)
    #expect(try cat.faces(forPerson: alice).count == 1)
    #expect(try cat.unassignedFacesWithEmbeddings().count == 1)
}

@Test func mergeAndDeletePerson() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let f = try cat.insertFaces([face(A, [1, 0]), face(B, [0, 1])])
    let alice = try cat.createPerson(name: "Alice")
    let al2   = try cat.createPerson(name: "Alice (dup)")
    try cat.assignFaces([f[0]], to: alice)
    try cat.assignFaces([f[1]], to: al2)
    try cat.mergePerson(al2, into: alice)
    #expect(try cat.faces(forPerson: alice).count == 2)
    #expect(try cat.people().map(\.id).contains(al2) == false)   // dup person gone
    // deletePerson reverts faces to unassigned.
    try cat.deletePerson(alice)
    #expect(try cat.people().isEmpty)
    #expect(try cat.unassignedFacesWithEmbeddings().count == 2)
}

@Test func peopleReturnsCountAndRepresentative() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    let f = try cat.insertFaces([face(A, [1, 0], conf: 0.5), face(A, [0, 1], conf: 0.95)])
    let p = try cat.createPerson(name: "Bob")
    try cat.assignFaces(f, to: p)
    let row = try #require(try cat.people().first)
    #expect(row.name == "Bob" && row.faceCount == 2)
    #expect(row.representativeFaceID == f[1])   // highest-confidence face
}

@Test func facesStageEligibility() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    #expect(try cat.pendingDerivation(stage: "faces") == [A])   // photos are faces-eligible
}

@Test func renamePersonUpdatesNameKeepsFaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    let f = try cat.insertFaces([face(A, [1, 0])])
    let p = try cat.createPerson(name: "Bob")
    try cat.assignFaces(f, to: p)
    try cat.renamePerson(p, to: "Robert")
    #expect(try cat.people().first?.name == "Robert")
    #expect(try cat.faces(forPerson: p).count == 1)   // faces untouched
}

@Test func faceForIDRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let ids = try cat.insertFaces([
        face(A, [1, 0], conf: 0.8),
        face(B, [0, 1], conf: 0.95)
    ])
    // Fetch by known id returns the right row.
    let rowA = try cat.face(forID: ids[0])
    let rowB = try cat.face(forID: ids[1])
    #expect(rowA?.hash == A)
    #expect(abs((rowA?.confidence ?? 0) - 0.8) < 0.01)
    #expect(rowB?.hash == B)
    #expect(abs((rowB?.confidence ?? 0) - 0.95) < 0.01)
    // Unknown id returns nil.
    #expect(try cat.face(forID: 9999) == nil)
}
