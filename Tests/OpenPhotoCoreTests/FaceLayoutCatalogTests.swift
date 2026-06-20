import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

private func photo(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}
private func face(_ hash: String, _ vec: [Float], personID: Int64? = nil) -> FaceRow {
    var v = vec; if v.count < FaceEmbedder.dimension { v += Array(repeating: 0, count: FaceEmbedder.dimension - v.count) }
    return FaceRow(id: nil, hash: hash, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                   embedding: v, confidence: 0.9, source: personID == nil ? "auto" : "confirmed",
                   personID: personID, quality: 1)
}
private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

@Test func faceLayoutRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let ids = try cat.insertFaces([face(A, [1,0]), face(B, [0,1])])
    try cat.writeFaceLayout([(ids[0], 0.5, -0.25), (ids[1], -0.5, 0.75)], version: 1)
    let read = try cat.readFaceLayout().sorted { $0.faceID < $1.faceID }
    #expect(read.count == 2)
    #expect(abs(read[0].x - 0.5) < 1e-4 && abs(read[0].y + 0.25) < 1e-4)
    // overwrite replaces, not appends
    try cat.writeFaceLayout([(ids[0], 0.1, 0.1)], version: 2)
    #expect(try cat.readFaceLayout().count == 1)
}

@Test func faceSetFingerprintChangesWithFaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    _ = try cat.insertFaces([face(A, [1,0])])
    let f1 = try cat.faceSetFingerprint()
    _ = try cat.insertFaces([face(B, [0,1])])
    let f2 = try cat.faceSetFingerprint()
    #expect(f1 != f2)
}

@Test func facesForLayoutIncludesAssignedAndUnassigned() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A), photo(B)])
    let alice = try cat.createPerson(name: "Alice")
    _ = try cat.insertFaces([face(A, [1,0]), face(B, [0,1], personID: alice)])
    let rows = try cat.facesForLayout()
    #expect(rows.count == 2)                                   // both assigned + unassigned
    #expect(rows.contains { $0.personID == alice })
    #expect(rows.contains { $0.personID == nil })
}
