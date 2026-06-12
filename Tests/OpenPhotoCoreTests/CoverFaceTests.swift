import Testing
import Foundation
@testable import OpenPhotoCore

// Shared fixtures — same pattern as FacesCRUDTests.swift
private func photo(_ h: String, takenAtMs: Int64 = 1) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let X = "sha256:" + String(repeating: "c", count: 64)
private let Y = "sha256:" + String(repeating: "d", count: 64)

private func coverFace(_ hash: String, _ vec: [Float], conf: Float = 0.9,
                       personID: Int64? = nil) -> FaceRow {
    FaceRow(id: nil, hash: hash, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
            embedding: vec, confidence: conf, source: "auto", personID: personID)
}

// (a) setPersonCover → people() returns that face as representativeFaceID
@Test func setPersonCoverSelectsCoverFace() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(X)])
    let f = try cat.insertFaces([
        coverFace(X, [1, 0], conf: 0.5),   // lower confidence
        coverFace(X, [0, 1], conf: 0.95),  // higher confidence (would normally win)
    ])
    let p = try cat.createPerson(name: "Alice")
    try cat.assignFaces(f, to: p)
    // Without cover set, highest-confidence (f[1]) wins — regression baseline.
    let before = try #require(try cat.people().first)
    #expect(before.representativeFaceID == f[1])
    // Set f[0] (lower confidence) as explicit cover.
    try cat.setPersonCover(personID: p, faceID: f[0])
    let after = try #require(try cat.people().first)
    #expect(after.representativeFaceID == f[0],
            "explicit cover should override confidence-based fallback")
}

// (b) cover face reassigned to ANOTHER person → people() for person A falls back to highest-confidence
@Test func coverFaceReassignedToOtherPersonFallsBack() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(X)])
    let f = try cat.insertFaces([
        coverFace(X, [1, 0], conf: 0.5),
        coverFace(X, [0, 1], conf: 0.95),
    ])
    let pA = try cat.createPerson(name: "Alice")
    let pB = try cat.createPerson(name: "Bob")
    try cat.assignFaces(f, to: pA)
    // Set f[0] as Alice's cover.
    try cat.setPersonCover(personID: pA, faceID: f[0])
    #expect(try cat.people().first { $0.name == "Alice" }?.representativeFaceID == f[0])
    // Reassign f[0] to Bob (face no longer belongs to Alice).
    try cat.assignFaces([f[0]], to: pB)
    // Alice's cover (f[0]) now belongs to Bob — COALESCE should fall back to f[1] (highest-conf for Alice).
    let aliceRow = try #require(try cat.people().first { $0.name == "Alice" })
    #expect(aliceRow.representativeFaceID == f[1],
            "stale cover (face belongs to another person) must fall back to highest-confidence")
}

// (c) setPersonCover(nil) clears → fallback to highest-confidence
@Test func clearPersonCoverFallsBackToHighestConfidence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(X)])
    let f = try cat.insertFaces([
        coverFace(X, [1, 0], conf: 0.5),
        coverFace(X, [0, 1], conf: 0.95),
    ])
    let p = try cat.createPerson(name: "Charlie")
    try cat.assignFaces(f, to: p)
    try cat.setPersonCover(personID: p, faceID: f[0])
    #expect(try cat.people().first?.representativeFaceID == f[0])
    // Clear cover.
    try cat.setPersonCover(personID: p, faceID: nil)
    let row = try #require(try cat.people().first)
    #expect(row.representativeFaceID == f[1],
            "nil cover clears back to highest-confidence fallback")
}

// (d) fresh catalog (no cover set) — regression: highest-confidence wins as before
@Test func freshCatalogNoCoverHighestConfidenceWins() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(X), photo(Y)])
    let f = try cat.insertFaces([
        coverFace(X, [1, 0], conf: 0.3),
        coverFace(X, [0, 1], conf: 0.8),
        coverFace(Y, [0.5, 0.5], conf: 0.6),
    ])
    let p = try cat.createPerson(name: "Dana")
    try cat.assignFaces(f, to: p)
    let row = try #require(try cat.people().first)
    #expect(row.representativeFaceID == f[1],
            "with no cover set, highest-confidence face should be representative (regression)")
}
