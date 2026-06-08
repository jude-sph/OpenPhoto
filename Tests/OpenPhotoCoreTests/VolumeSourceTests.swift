import Testing
import Foundation
@testable import OpenPhotoCore

@Test func enumeratesMediaNewestFirstAndFetches() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/100APPLE/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2026:01:01 10:00:00", lat: nil, lon: nil)
    try makeJPEG(at: card.appendingPathComponent("DCIM/100APPLE/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2026:03:01 10:00:00", lat: nil, lon: nil)
    try t.file("CARD/DCIM/notes.txt", Data("x".utf8))
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    #expect(items.count == 2)
    #expect(items[0].name == "IMG_2.jpg")          // newest first
    #expect(items[0].byteSize > 0)
    let dest = t.root.appendingPathComponent("out.jpg")
    try await src.fetch(items[0], to: dest)
    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(await src.thumbnail(items[0], maxPixel: 64) != nil)
}

@Test func deleteMovesToVolumeTrashNeverUnlinks() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/IMG_9.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    let results = try await src.delete(items)
    #expect(results == [DeleteResult(itemID: items[0].id, error: nil)])
    #expect(!FileManager.default.fileExists(
        atPath: card.appendingPathComponent("DCIM/IMG_9.jpg").path))
    #expect(FileManager.default.fileExists(
        atPath: card.appendingPathComponent(".openphoto-trash/DCIM/IMG_9.jpg").path))
}

@Test func deleteIsIdempotentOnRepeat() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/IMG_A.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    #expect(items.count == 1)
    // First delete.
    let r1 = try await src.delete(items)
    #expect(r1[0].error == nil)
    #expect(!FileManager.default.fileExists(
        atPath: card.appendingPathComponent("DCIM/IMG_A.jpg").path))
    #expect(FileManager.default.fileExists(
        atPath: card.appendingPathComponent(".openphoto-trash/DCIM/IMG_A.jpg").path))
    // Second delete — source file already gone; must still succeed (idempotent).
    let r2 = try await src.delete(items)
    #expect(r2[0].error == nil)
    // Trashed file still there.
    #expect(FileManager.default.fileExists(
        atPath: card.appendingPathComponent(".openphoto-trash/DCIM/IMG_A.jpg").path))
}

@Test func emptyTrashRemovesTrashedFiles() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    try makeJPEG(at: card.appendingPathComponent("DCIM/IMG_B.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    let src = VolumeSource(rootURL: card, displayName: "Test Card")
    let items = try await src.enumerateItems()
    _ = try await src.delete(items)
    let count1 = await src.reclaimableTrashCount()
    #expect(count1 == 1)
    try await src.emptyTrash()
    let count2 = await src.reclaimableTrashCount()
    #expect(count2 == 0)
    // .openphoto-trash directory itself should be gone or empty.
    let trashDir = card.appendingPathComponent(".openphoto-trash")
    let exists = FileManager.default.fileExists(atPath: trashDir.path)
    if exists {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []
        #expect(contents.isEmpty)
    }
}

@Test func sourceKeyStableForSameRoot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let card = try t.sub("CARD")
    let a = VolumeSource(rootURL: card, displayName: "C")
    let b = VolumeSource(rootURL: card, displayName: "C")
    #expect(a.sourceKey == b.sourceKey && !a.sourceKey.isEmpty)
}
