import Testing
import Foundation
@testable import OpenPhotoCore

private func fakeHash(_ c: Character) -> ContentHash {
    ContentHash(stringValue: "sha256:" + String(repeating: c, count: 64))
}

@Test func batchMoveToBinLogsOnceAndAttributesFailures() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/a/1.jpg", Data("1".utf8))
    try t.file("Pictures/a/.openphoto/1.jpg.xmp", Data("<x/>".utf8))
    try t.file("Pictures/b/2.jpg", Data("2".utf8))
    try t.file("Pictures/old.jpg", Data("o".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)
    try bin.moveToBin(relPath: "old.jpg", hash: fakeHash("0"), origin: .propagated)   // pre-existing line

    let failures = bin.moveToBin([
        .init(relPath: "a/1.jpg", hash: fakeHash("a"), origin: .user),
        .init(relPath: "missing/nope.jpg", hash: fakeHash("c"), origin: .user),
        .init(relPath: "b/2.jpg", hash: fakeHash("b"), origin: .repaired),
    ])

    #expect(Array(failures.keys) == [1])                       // only the missing file failed
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: root.appendingPathComponent(".openphoto/bin/a/1.jpg").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent(".openphoto/bin/a/.openphoto/1.jpg.xmp").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent(".openphoto/bin/b/2.jpg").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("a/1.jpg").path))
    let items = try bin.list()
    #expect(items.map(\.path) == ["old.jpg", "a/1.jpg", "b/2.jpg"])   // appended in order; failed one absent
    #expect(items.map(\.origin) == [.propagated, .user, .repaired])
    #expect(items[1].hash == fakeHash("a").stringValue)
}

@Test func batchRestorePutsFilesBackAndKeepsUnrestoredLines() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    for n in ["a/1.jpg", "a/2.jpg", "b/3.jpg"] { try t.file("Pictures/" + n, Data(n.utf8)) }
    try t.file("Pictures/a/.openphoto/1.jpg.xmp", Data("<x/>".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)
    #expect(bin.moveToBin(["a/1.jpg", "a/2.jpg", "b/3.jpg"].map {
        BinStore.BinMove(relPath: $0, hash: fakeHash("d"), origin: .user)
    }).isEmpty)

    let failures = bin.restore(relPaths: ["a/1.jpg", "never/binned.jpg", "b/3.jpg"])

    #expect(Array(failures.keys) == [1])
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: root.appendingPathComponent("a/1.jpg").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("a/.openphoto/1.jpg.xmp").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("b/3.jpg").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("a/2.jpg").path))
    #expect(try bin.list().map(\.path) == ["a/2.jpg"])
}

@Test func batchEnqueueAndDequeuePendingDeletions() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let catalog = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try catalog.enqueuePendingDeletions([("h1", "a/1.jpg"), ("h2", "a/2.jpg"), ("h1", "b/1.jpg")],
                                        deletedAtMs: 42)
    let q = try catalog.pendingDeletions()
    #expect(Set(q.map(\.hash)) == ["h1", "h2"])
    #expect(q.first { $0.hash == "h1" }?.relPath == "b/1.jpg")      // last write wins, as in a loop
    #expect(q.allSatisfy { $0.deletedAtMs == 42 })
    try catalog.dequeuePendingDeletions(hashes: ["h1", "nope"])
    #expect(try catalog.pendingDeletions().map(\.hash) == ["h2"])
}

/// Deleting a selection bins every file, logs each once, queues each for propagation, and a
/// file that is already gone is skipped (not counted) without stopping the rest.
@Test func libraryDeleteManyBinsLogsAndQueuesEach() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    for i in 1...4 {
        try makeJPEG(at: pics.appendingPathComponent("trip/IMG_\(i).jpg").creatingParent(),
                     dateTimeOriginal: "2022:10:0\(i) 14:23:01", lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("appsupport"))
    try await lib.scanAll()
    let items = try lib.items(inDir: "trip")
    #expect(items.count == 4)
    // One file vanishes behind the app's back before the delete.
    let gone = items.first { $0.relPath == "trip/IMG_2.jpg" }!
    try FileManager.default.removeItem(at: pics.appendingPathComponent(gone.relPath))

    let n = try await lib.delete(items)

    #expect(n == 3)
    #expect(try lib.items(inDir: "trip").isEmpty)
    let binned = try lib.binItems()
    #expect(Set(binned.map(\.item.path)) == ["trip/IMG_1.jpg", "trip/IMG_3.jpg", "trip/IMG_4.jpg"])
    #expect(binned.allSatisfy { $0.item.origin == .user })
    let queued = Set(try lib.catalog.pendingDeletions().map(\.hash))
    #expect(queued == Set(items.filter { $0.hash != gone.hash }.map(\.hash)))
}
