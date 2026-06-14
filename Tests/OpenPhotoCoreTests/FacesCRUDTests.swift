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

@Test func replaceFacesRefreshesConfirmedFromOverlappingDetection() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    let ids = try cat.insertFaces([face(A, [0, 1], source: "confirmed", quality: 0.4,
                                        rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))])
    let confirmedID = ids[0]
    // Re-detection re-finds the named face (overlapping rect) with a fresh vector + a new face elsewhere.
    try cat.replaceFaces(forHash: A, with: [
        face(A, [1, 0], quality: 0.9, rect: CGRect(x: 0.21, y: 0.21, width: 0.3, height: 0.3)),  // overlaps
        face(A, [0, 0, 1], quality: 0.8, rect: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)),  // new
    ])
    let rows = try cat.faces(forHash: A)
    #expect(rows.filter { $0.source == "confirmed" }.count == 1)  // named face kept, not duplicated
    #expect(rows.filter { $0.source == "auto" }.count == 1)       // only the non-overlapping new auto
    // The named face kept its identity but took the fresh embedding + quality from the new detection.
    let refreshed = try #require(try cat.face(forID: confirmedID))
    #expect(refreshed.source == "confirmed")
    #expect(abs(refreshed.quality - 0.9) < 0.01)
    #expect((refreshed.embedding.first ?? 0) > 0.5)   // now ~[1,0,…], was [0,1,…]
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

@Test func manualPersonTagIsViewableButExcludedFromTheAlgorithm() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    let bob = try cat.createPerson(name: "Bob")

    let fid = try #require(try cat.addManualPersonTag(hash: A, personID: bob))
    #expect(try cat.addManualPersonTag(hash: A, personID: bob) == nil)   // idempotent

    // Visible in Bob's grid…
    #expect(try cat.faces(forPerson: bob).contains { $0.id == fid })
    // …but excluded from centroids (no current-model embedding) and from the clusterable pool,
    // and it's assigned so it isn't in the Other-faces (unassigned) set either.
    #expect(try cat.assignedFacesWithEmbeddings().isEmpty)
    #expect(try cat.unassignedFacesWithEmbeddings().isEmpty)
    #expect(try !cat.unassignedAutoFaceIDs().contains(fid))

    // Removing a manual tag deletes it rather than returning a no-face row to the pool.
    try cat.reassignFace(fid, to: nil)
    #expect(try cat.faces(forHash: A).isEmpty)
}

@Test func reconcileFaceModelResetsOnceOnVersionChange() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    _ = try cat.insertFaces([
        face(A, [1, 0]),
        face(A, [0, 1], source: "confirmed", rect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))])
    try cat.markDerived(hash: A, stage: "faces")

    // No stored version yet → reconcile resets: drops auto, keeps confirmed, re-pends the job, stamps.
    #expect(try cat.reconcileFaceModel(current: "adaface-ir101-v1") == true)
    let rows = try cat.faces(forHash: A)
    #expect(rows.filter { $0.source == "auto" }.isEmpty)
    #expect(rows.filter { $0.source == "confirmed" }.count == 1)
    #expect(try cat.pendingDerivation(stage: "faces") == [A])   // job cleared → faces re-pend
    #expect(try cat.meta("faceModelVersion") == "adaface-ir101-v1")

    // Same version again → no-op (doesn't re-clear on every launch).
    #expect(try cat.reconcileFaceModel(current: "adaface-ir101-v1") == false)
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
