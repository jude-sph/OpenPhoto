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

// MARK: - Regression tests for bugs found in the Nov 2026 hunt

@Test func renameReattachesDroppedExtensionAndRejectsPathEscapes() throws {
    #expect(try LibraryService.sanitizedRename("Beach sunset", original: "IMG_1.HEIC") == "Beach sunset.HEIC")
    #expect(try LibraryService.sanitizedRename("  beach.heic ", original: "IMG_1.HEIC") == "beach.heic")
    #expect(try LibraryService.sanitizedRename("beach.jpg", original: "IMG_1.HEIC") == "beach.jpg.HEIC")
    #expect(try LibraryService.sanitizedRename("v1.2 final", original: "a.mov") == "v1.2 final.mov")
    for bad in ["", "   ", "../x.jpg", "a/b.jpg", ".hidden.jpg", ".HEIC"] {
        #expect(throws: (any Error).self) { try LibraryService.sanitizedRename(bad, original: "IMG_1.HEIC") }
    }
}

@Test func verifiedCopyCarriesMtimeAndFinderTags() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = t.root.appendingPathComponent("src.jpg"), dst = t.root.appendingPathComponent("out/dst.jpg")
    try Data("payload".utf8).write(to: src)
    let old = Date(timeIntervalSince1970: 1_500_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)
    let tagBytes: [UInt8] = Array("fake-tag-plist".utf8)
    #expect(setxattr(src.path, "com.apple.metadata:_kMDItemUserTags", tagBytes, tagBytes.count, 0, 0) == 0)

    let hash = try ContentHash.ofFile(at: src).stringValue
    #expect(VerifiedCopy.copy(from: src, to: dst, expectedHash: hash) == .copied)

    let m = try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date
    #expect(abs((m ?? .distantFuture).timeIntervalSince(old)) < 1)
    var buf = [UInt8](repeating: 0, count: 64)
    let n = getxattr(dst.path, "com.apple.metadata:_kMDItemUserTags", &buf, 64, 0, 0)
    #expect(n == tagBytes.count && Array(buf[0..<max(n, 0)]) == tagBytes)
}

@Test func pendingDeletionOfContentStillInLibraryIsPurged() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "mac", role: "local", rootPath: "/tmp/mac")
    try cat.upsert(instances: [InstanceRecord(hash: "sha256:keep", vaultID: "mac", relPath: "B/x.jpg",
                                              dirPath: "B", size: 1, mtimeMs: 0)])
    try cat.enqueuePendingDeletion(hash: "sha256:keep", relPath: "A/x.jpg", deletedAtMs: 1)   // duplicate deleted
    try cat.enqueuePendingDeletion(hash: "sha256:gone", relPath: "C/y.jpg", deletedAtMs: 1)   // really deleted
    try cat.purgePendingDeletionsStillInLibrary()
    #expect(try cat.pendingDeletions().map(\.hash) == ["sha256:gone"])
}
