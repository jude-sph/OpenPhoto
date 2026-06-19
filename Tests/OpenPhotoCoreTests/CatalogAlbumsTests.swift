import Testing
import Foundation
import GRDB
@testable import OpenPhotoCore

private func aAsset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                caption: nil, tagsJSON: "[]")
}
private func aInst(_ h: String, _ rel: String) -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: "mac", relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 10, mtimeMs: 1)
}
private func aRec(_ id: String, _ name: String, _ members: [String]) -> AlbumRecord {
    AlbumRecord(id: id, name: name, createdAtMs: 1, modifiedAtMs: 1, members: members)
}
private let H1 = "sha256:" + String(repeating: "1", count: 64)   // in /A (lockable)
private let H2 = "sha256:" + String(repeating: "2", count: 64)   // in /B
private let H3 = "sha256:" + String(repeating: "3", count: 64)   // in /B

/// Catalog with three photos: H1 in /A, H2 & H3 in /B.
private func seededCatalog() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [aAsset(H1), aAsset(H2), aAsset(H3)])
    try cat.replaceInstances(inVault: "mac", with: [
        aInst(H1, "A/1.jpg"), aInst(H2, "B/2.jpg"), aInst(H3, "B/3.jpg"),
    ])
    return (t, cat)
}

@Test func itemsInAlbumReturnsMembersInStoredOrder() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.replaceAlbums([aRec("al", "Mix", [H3, H1, H2])])   // deliberate non-sorted order
    #expect(try cat.itemsInAlbum(id: "al").map(\.hash) == [H3, H1, H2])
}

@Test func itemsInAlbumHonorsLockGate() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])                          // locks H1 (in /A)
    try cat.replaceAlbums([aRec("al", "Mix", [H1, H2, H3])])

    cat.revealLocked = false
    #expect(try cat.itemsInAlbum(id: "al").map(\.hash) == [H2, H3])      // H1 hidden, order kept
    cat.revealLocked = true
    #expect(try cat.itemsInAlbum(id: "al").map(\.hash) == [H1, H2, H3])  // all shown
}

@Test func upsertAlbumReordersMembers() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.replaceAlbums([aRec("al", "Mix", [H1, H2, H3])])
    try cat.upsertAlbum(aRec("al", "Mix", [H3, H2, H1]))
    #expect(try cat.itemsInAlbum(id: "al").map(\.hash) == [H3, H2, H1])
}

@Test func albumDedupsRepeatedHash() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.replaceAlbums([aRec("al", "Mix", [H1, H1, H2])])   // H1 listed twice
    #expect(try cat.itemsInAlbum(id: "al").map(\.hash) == [H1, H2])
}

@Test func albumIDsContainingHash() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.replaceAlbums([aRec("a1", "One", [H1, H2]), aRec("a2", "Two", [H2])])
    #expect(try cat.albumIDsContaining(hash: H2) == ["a1", "a2"])
    #expect(try cat.albumIDsContaining(hash: H1) == ["a1"])
    #expect(try cat.albumIDsContaining(hash: H3).isEmpty)
}

@Test func albumSummariesCountHonorsLockGate() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])                          // locks H1
    try cat.replaceAlbums([aRec("al", "Mix", [H1, H2, H3])])

    cat.revealLocked = false
    let hidden = try cat.albumSummaries()
    #expect(hidden.count == 1 && hidden[0].count == 2)         // H1 not counted
    cat.revealLocked = true
    #expect(try cat.albumSummaries()[0].count == 3)
}

@Test func deleteAlbumMirrorRemovesAlbumAndMembers() throws {
    let (t, cat) = try seededCatalog(); defer { t.cleanup() }
    try cat.replaceAlbums([aRec("al", "Mix", [H1])])
    try cat.deleteAlbumMirror(id: "al")
    #expect(try cat.albumSummaries().isEmpty)
    #expect(try cat.itemsInAlbum(id: "al").isEmpty)
}
