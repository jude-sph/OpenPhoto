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

@Test func albumStoreSyncToDriveMirrorsAndPropagatesDeletes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try t.sub("lib")
    let driveState = try t.sub("drive/.openphoto")
    // Source library has albums A and B.
    try AlbumStore.save(album("A", "Alpha", members: ["h1"]), libraryRoot: lib)
    try AlbumStore.save(album("B", "Bravo"), libraryRoot: lib)
    // Drive already has a stale B and an orphan C (no longer on source).
    let driveAlbums = driveState.appendingPathComponent("albums")
    try FileManager.default.createDirectory(at: driveAlbums, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: driveAlbums.appendingPathComponent("B.json"))
    try Data("orphan".utf8).write(to: driveAlbums.appendingPathComponent("C.json"))

    try AlbumStore.syncToDrive(libraryRoot: lib, driveStateDir: driveState)

    // Drive now mirrors source exactly: A + fresh B, C gone.
    let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: driveAlbums.path)) ?? []))
    #expect(names == ["A.json", "B.json", StateFileBin.dirName])     // C binned, not removed
    let driveB = try Data(contentsOf: driveAlbums.appendingPathComponent("B.json"))
    #expect((try? JSONDecoder().decode(AlbumRecord.self, from: driveB))?.name == "Bravo")  // overwritten
}

@Test func albumStoreLoadSingle() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try AlbumStore.save(album("x", "X", members: ["h1"]), libraryRoot: t.root)
    #expect(AlbumStore.load(id: "x", libraryRoot: t.root)?.members == ["h1"])
    #expect(AlbumStore.load(id: "nope", libraryRoot: t.root) == nil)
}

// Nothing hard-deletes: a deleted album's file moves into `albums/.bin/` (on the Mac, and on the
// drive when the mirror propagates the deletion), where loadAll never sees it.
@Test func albumDeleteBinsTheFileInsteadOfRemovingIt() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try t.sub("lib"), driveState = try t.sub("drive/.openphoto")
    try AlbumStore.save(album("a", "Keep me", members: ["sha256:1"]), libraryRoot: lib)
    try AlbumStore.syncToDrive(libraryRoot: lib, driveStateDir: driveState)
    AlbumStore.delete(id: "a", libraryRoot: lib)
    try AlbumStore.save(album("a", "Recreated"), libraryRoot: lib)
    AlbumStore.delete(id: "a", libraryRoot: lib)                       // a second deletion of the same id
    #expect(AlbumStore.loadAll(libraryRoot: lib).isEmpty)
    let bin = AlbumStore.directoryURL(libraryRoot: lib).appendingPathComponent(StateFileBin.dirName)
    let binned = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
    #expect(binned.count == 2)                                         // both versions kept
    let names = try binned.map { try JSONDecoder().decode(AlbumRecord.self, from: Data(contentsOf: $0)).name }
    #expect(Set(names) == ["Keep me", "Recreated"])

    try AlbumStore.syncToDrive(libraryRoot: lib, driveStateDir: driveState)
    let dAlbums = driveState.appendingPathComponent("albums")
    #expect(!FileManager.default.fileExists(atPath: dAlbums.appendingPathComponent("a.json").path))
    let dBinned = try FileManager.default.contentsOfDirectory(
        at: dAlbums.appendingPathComponent(StateFileBin.dirName), includingPropertiesForKeys: nil)
    #expect(dBinned.count == 1)
}
