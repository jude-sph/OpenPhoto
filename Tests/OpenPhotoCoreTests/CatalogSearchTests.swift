import Testing
import Foundation
@testable import OpenPhotoCore

private func asset(_ h: String, takenAtMs: Int64, camera: String? = nil, rating: Int = 0,
                   favorite: Bool = false, kind: String = "photo", caption: String? = nil,
                   tags: [String] = []) -> AssetRecord {
    let tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8) ?? "[]") ?? "[]"
    return AssetRecord(hash: h, kind: kind, takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: camera, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: favorite, rating: rating,
        caption: caption, tagsJSON: tagsJSON)
}

/// Seed an asset into the catalog with a local instance so the timeline union returns the row.
/// Uses cat.upsert(instances:) — the real API (not upsertInstances).
private func seedLocal(_ cat: Catalog, _ a: AssetRecord) throws {
    try cat.upsert(assets: [a])
    try cat.upsert(instances: [InstanceRecord(hash: a.hash, vaultID: "v", relPath: a.hash + ".jpg",
        dirPath: "", size: 1, mtimeMs: 1)])
}

private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

@Test func structuredFiltersIsolateAndCombine() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 2000, camera: "Sony", rating: 5, favorite: true,
                             tags: ["rome", "trip"]))
    try seedLocal(cat, asset(B, takenAtMs: 1000, camera: "Canon", rating: 2, tags: ["rome"]))

    #expect(try cat.structuredFilter(.init(camera: "Sony")) == [A])
    #expect(try cat.structuredFilter(.init(minRating: 5)) == [A])
    #expect(try cat.structuredFilter(.init(favoritesOnly: true)) == [A])
    #expect(Set(try cat.structuredFilter(.init(tags: ["rome"]))) == Set([A, B]))
    #expect(try cat.structuredFilter(.init(tags: ["rome", "trip"])) == [A])   // AND semantics
    #expect(try cat.structuredFilter(.init(camera: "Sony", minRating: 5)) == [A])
}

@Test func itemsForHashesPreservesOrder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 1000))
    try seedLocal(cat, asset(B, takenAtMs: 2000))
    let items = try cat.items(forHashes: [B, A], preservingOrder: true)
    #expect(items.map(\.hash) == [B, A])     // honors the given order, not takenAtMs
}

@Test func personFilterNarrowsToThatPersonsPhotos() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    // Seed two assets: A has Alice's face; B does not.
    try seedLocal(cat, asset(A, takenAtMs: 2000))
    try seedLocal(cat, asset(B, takenAtMs: 1000))
    let f = try cat.insertFaces([FaceRow(id: nil, hash: A,
        rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), embedding: [1, 0],
        confidence: 0.9, source: "auto", personID: nil)])
    let alice = try cat.createPerson(name: "Alice")
    try cat.assignFaces(f, to: alice)
    // Only A has Alice's face.
    #expect(try cat.structuredFilter(.init(person: alice)) == [A])
    // Composing person filter with favoritesOnly: A is not a favorite → empty.
    #expect(try cat.structuredFilter(.init(favoritesOnly: true, person: alice)).isEmpty)
}

@Test func distinctCamerasAndTags() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 1, camera: "Sony", tags: ["rome", "trip"]))
    try seedLocal(cat, asset(B, takenAtMs: 2, camera: "Canon", tags: ["rome"]))
    #expect(Set(try cat.distinctCameras()) == Set(["Sony", "Canon"]))
    #expect(Set(try cat.distinctTags()) == Set(["rome", "trip"]))
}
