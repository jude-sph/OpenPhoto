import Testing
import Foundation
@testable import OpenPhotoCore

private func album(_ id: String, _ name: String, members: [String] = []) -> AlbumRecord {
    AlbumRecord(id: id, name: name, createdAtMs: 1, modifiedAtMs: 1, members: members)
}

@Test func albumStoreSaveLoadRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try AlbumStore.save(album("id-a", "Birthdays", members: ["sha256:1", "sha256:2"]), libraryRoot: t.root)
    try AlbumStore.save(album("id-b", "Aardvarks"), libraryRoot: t.root)

    let loaded = AlbumStore.loadAll(libraryRoot: t.root)
    #expect(loaded.count == 2)
    #expect(loaded.map(\.name) == ["Aardvarks", "Birthdays"])           // sorted by name
    #expect(loaded.first { $0.id == "id-a" }?.members == ["sha256:1", "sha256:2"])  // order preserved
}

@Test func albumStoreSkipsCorruptFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try AlbumStore.save(album("good", "Good"), libraryRoot: t.root)
    let bad = AlbumStore.directoryURL(libraryRoot: t.root).appendingPathComponent("bad.json")
    try Data("not json".utf8).write(to: bad)

    let loaded = AlbumStore.loadAll(libraryRoot: t.root)
    #expect(loaded.count == 1 && loaded[0].id == "good")               // corrupt skipped, valid kept
}

@Test func albumStoreDeleteRemovesOne() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try AlbumStore.save(album("a", "A"), libraryRoot: t.root)
    try AlbumStore.save(album("b", "B"), libraryRoot: t.root)
    AlbumStore.delete(id: "a", libraryRoot: t.root)
    let loaded = AlbumStore.loadAll(libraryRoot: t.root)
    #expect(loaded.count == 1 && loaded[0].id == "b")
}

@Test func albumStoreLoadSingle() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try AlbumStore.save(album("x", "X", members: ["h1"]), libraryRoot: t.root)
    #expect(AlbumStore.load(id: "x", libraryRoot: t.root)?.members == ["h1"])
    #expect(AlbumStore.load(id: "nope", libraryRoot: t.root) == nil)
}
