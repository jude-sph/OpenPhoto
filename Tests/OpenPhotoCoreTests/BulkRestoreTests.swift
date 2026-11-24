import Testing
import Foundation
@testable import OpenPhotoCore

private func makeTripLibrary(_ t: TestDirs, count: Int) throws -> (LibraryService, URL) {
    let pics = try t.sub("Pictures")
    for i in 1...count {
        try makeJPEG(at: pics.appendingPathComponent("trip/IMG_\(i).jpg").creatingParent(),
                     dateTimeOriginal: "2022:10:0\(i) 14:23:01", lat: nil, lon: nil)
    }
    return (try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("appsupport")), pics)
}

@Test func bulkRestoreBringsEverythingBackAndDequeues() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, pics) = try makeTripLibrary(t, count: 4)
    try await lib.scanAll()
    let items = try lib.items(inDir: "trip")
    // Human metadata must survive the round trip (sidecar travels with the file).
    try lib.updateMetadata(for: items[0], rating: 5, favorite: true, caption: "keep", tags: ["t"])
    try await lib.delete(items)
    #expect(try lib.items(inDir: "trip").isEmpty)
    #expect(try lib.catalog.pendingDeletions().count == 4)

    let entries = try lib.binItems()
    #expect(entries.count == 4)
    let restored = try await lib.restore(entries)

    #expect(restored.count == 4)
    #expect(try lib.binItems().isEmpty)
    #expect(try lib.catalog.pendingDeletions().isEmpty)
    let back = try lib.items(inDir: "trip")
    #expect(Set(back.map(\.relPath)) == Set(items.map(\.relPath)))
    #expect(back.first { $0.hash == items[0].hash }?.rating == 5)
    for it in items {
        #expect(FileManager.default.fileExists(atPath: pics.appendingPathComponent(it.relPath).path))
    }
}

/// An entry whose binned file is gone is skipped; the others are still restored, their log
/// lines dropped, and the catalog rescanned.
@Test func bulkRestoreSkipsUnrestorableEntryAndKeepsItsLogLine() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, _) = try makeTripLibrary(t, count: 3)
    try await lib.scanAll()
    try await lib.delete(try lib.items(inDir: "trip"))
    let entries = try lib.binItems()
    let broken = entries.first { $0.item.path == "trip/IMG_2.jpg" }!
    try FileManager.default.removeItem(at: broken.fileURL)

    let restored = try await lib.restore(entries)

    #expect(Set(restored.map(\.item.path)) == ["trip/IMG_1.jpg", "trip/IMG_3.jpg"])
    #expect(try lib.binItems().map(\.item.path) == ["trip/IMG_2.jpg"])
    #expect(Set(try lib.items(inDir: "trip").map(\.relPath)) == ["trip/IMG_1.jpg", "trip/IMG_3.jpg"])
    // The unrestored photo stays queued for propagation; the restored ones do not.
    #expect(try lib.catalog.pendingDeletions().map(\.hash) == [broken.item.hash])
}

@Test func singleRestoreStillThrowsWhenTheFileIsGone() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, _) = try makeTripLibrary(t, count: 1)
    try await lib.scanAll()
    try await lib.delete(try lib.items(inDir: "trip"))
    let entry = try lib.binItems()[0]
    try FileManager.default.removeItem(at: entry.fileURL)
    await #expect(throws: (any Error).self) { try await lib.restore(entry) }
    #expect(try lib.catalog.pendingDeletions().count == 1)   // still queued — nothing was restored
}

/// Restoring a Live Photo still also dequeues its paired video (single + batch share the path).
@Test func bulkRestoreDequeuesLivePair() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, _) = try makeTripLibrary(t, count: 2)
    try await lib.scanAll()
    let items = try lib.items(inDir: "trip")
    let still = items[0], video = items[1]
    try lib.catalog.setLivePair(photoHash: still.hash, videoHash: video.hash)
    let bin = BinStore(vault: lib.vaults[0])
    try bin.moveToBin(relPath: still.relPath, hash: ContentHash(stringValue: still.hash), origin: .user)
    try lib.catalog.enqueuePendingDeletions([(still.hash, still.relPath), (video.hash, video.relPath)],
                                            deletedAtMs: 1)

    let restored = try await lib.restore(try lib.binItems())

    #expect(restored.count == 1)
    #expect(try lib.catalog.pendingDeletions().isEmpty)
}
