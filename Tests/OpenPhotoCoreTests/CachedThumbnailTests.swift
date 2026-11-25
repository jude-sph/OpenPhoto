import Testing
import Foundation
@testable import OpenPhotoCore

@Test func cachedDisplayImageServesAfterSourceGone() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let thumbs = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let src = try t.sub("src").appendingPathComponent("a.jpg")
    try makeJPEG(at: src, dateTimeOriginal: nil, lat: nil, lon: nil)
    let hash = ContentHash(stringValue: try ContentHash.ofFile(at: src).stringValue)
    _ = try await thumbs.thumbnail(for: hash, sourceURL: src, kind: .photo)   // populate cache
    try FileManager.default.removeItem(at: src)                               // "unplug" the source
    #expect(await thumbs.cachedDisplayImage(for: hash, maxPixel: 128) != nil)
    let unknown = ContentHash(stringValue: "sha256:" + String(repeating: "0", count: 64))
    #expect(await thumbs.cachedDisplayImage(for: unknown, maxPixel: 128) == nil)
}

// The cache file is written via a temp + rename: only the final JPEG is left behind.
@Test func thumbnailCacheWriteLeavesOnlyTheFinalFile() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let thumbs = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let src = try t.sub("src").appendingPathComponent("a.jpg")
    try makeJPEG(at: src, dateTimeOriginal: nil, lat: nil, lon: nil)
    let hash = ContentHash(stringValue: try ContentHash.ofFile(at: src).stringValue)
    async let a = thumbs.thumbnail(for: hash, sourceURL: src, kind: .photo)
    async let b = thumbs.thumbnail(for: hash, sourceURL: src, kind: .photo)
    _ = try await (a, b)
    let url = thumbs.cacheURL(for: hash)
    let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(files == [url.lastPathComponent])
    #expect(await thumbs.cachedDisplayImage(for: hash, maxPixel: 64) != nil)
}
