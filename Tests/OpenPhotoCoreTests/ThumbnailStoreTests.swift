import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

@Test func generatesAndCachesImageThumb() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let img = t.root.appendingPathComponent("p.jpg")
    try makeJPEG(at: img, dateTimeOriginal: nil, lat: nil, lon: nil)
    let store = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "d", count: 64))
    let cg1 = try await store.thumbnail(for: h, sourceURL: img, kind: .photo)
    #expect(cg1 != nil)
    #expect(FileManager.default.fileExists(atPath: store.cacheURL(for: h).path))
    // Second call serves from cache even if the source is gone (evicted files).
    try FileManager.default.removeItem(at: img)
    #expect(try await store.thumbnail(for: h, sourceURL: img, kind: .photo) != nil)
}

@Test func generatesVideoThumb() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let mov = t.root.appendingPathComponent("c.mov")
    try await makeMOV(at: mov)
    let store = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "e", count: 64))
    #expect(try await store.thumbnail(for: h, sourceURL: mov, kind: .video) != nil)
}
