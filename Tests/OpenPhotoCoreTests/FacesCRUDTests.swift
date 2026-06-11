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
                  personID: Int64? = nil, conf: Float = 0.9) -> FaceRow {
    FaceRow(id: nil, hash: hash, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
            embedding: vec, confidence: conf, source: source, personID: personID)
}

@Test func replaceFacesKeepsConfirmedDropsAuto() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    // Seed one auto + one confirmed face on A.
    let ids = try cat.insertFaces([face(A, [1, 0]), face(A, [0, 1], source: "confirmed")])
    #expect(ids.count == 2)
    // Re-detect → replaceFaces with a fresh auto row.
    try cat.replaceFaces(forHash: A, with: [face(A, [0.5, 0.5])])
    let rows = try cat.faces(forHash: A)
    #expect(rows.filter { $0.source == "confirmed" }.count == 1)  // confirmed survived
    #expect(rows.filter { $0.source == "auto" }.count == 1)       // old auto replaced by new auto
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
