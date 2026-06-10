import Testing
import Foundation
@testable import OpenPhotoCore

// MARK: - mediaFiles(under:)

@Test func mediaFilesReturnsOnlyMediaAndSkipsStateDir() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let a = try t.sub("a"), b = try t.sub("b")
    try makeJPEG(at: a.appendingPathComponent("x.jpg"), dateTimeOriginal: nil, lat: nil, lon: nil)
    try await Task { try await makeMOV(at: b.appendingPathComponent("y.mov")) }.value
    // A .openphoto/ dir with a stray jpg inside — must be skipped wholesale.
    let state = try t.sub(".openphoto")
    try makeJPEG(at: state.appendingPathComponent("stray.jpg"), dateTimeOriginal: nil, lat: nil, lon: nil)
    // A non-media file — must be skipped.
    try Data("hi".utf8).write(to: t.root.appendingPathComponent("notes.txt"))

    let urls = PeekSource.mediaFiles(under: t.root)
    let names = urls.map(\.lastPathComponent).sorted()
    #expect(names == ["x.jpg", "y.mov"])
    #expect(!urls.contains { $0.path.contains("/.openphoto/") })
}

// MARK: - raw load (no snapshot)

@Test func loadRawFolderBuildsOneItemPerMediaFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.sub("src")
    let jpg = src.appendingPathComponent("p.jpg")
    try makeJPEG(at: jpg, dateTimeOriginal: nil, lat: nil, lon: nil)
    let jpg2 = src.appendingPathComponent("q.jpg")
    try makeJPEG(at: jpg2, dateTimeOriginal: nil, lat: nil, lon: nil)
    let tmp = t.root.appendingPathComponent("peek-tmp")

    let ctx = try PeekSource.load(root: src, tempDir: tmp)

    #expect(ctx.items.count == 2)
    #expect(ctx.root == src)
    #expect(Set(ctx.items.map(\.sourceURL.lastPathComponent)) == ["p.jpg", "q.jpg"])
    #expect(ctx.items.allSatisfy { $0.kind == .photo })
    // Distinct synthetic thumb hashes (path-derived).
    #expect(Set(ctx.items.map(\.thumbHash.stringValue)).count == 2)
    // The throwaway thumbnail cache lives under tempDir.
    for item in ctx.items {
        #expect(ctx.thumbnails.cacheURL(for: item.thumbHash).path.hasPrefix(tmp.path))
    }
}

// MARK: - snapshot load

/// Build a canonical drive carrying a catalog-snapshot (manifest + presence + a cached thumb), as in
/// CatalogSnapshotTests. Returns (driveRoot, driveHash).
private func snapshotDrive(_ t: TestDirs) throws -> (URL, String) {
    let catalog = try Catalog(at: t.root.appendingPathComponent("seed.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: try t.sub("seed-thumbs"))
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let driveHash = "sha256:" + String(repeating: "a", count: 64)
    try catalog.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: driveHash),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    let u = thumbs.cacheURL(for: ContentHash(stringValue: driveHash))
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("jpg".utf8).write(to: u)
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)
    return (drive.rootURL, driveHash)
}

@Test func loadSnapshotDriveReadsIndexIntoTempCatalog() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (driveRoot, driveHash) = try snapshotDrive(t)
    let tmp = t.root.appendingPathComponent("peek-tmp")

    let ctx = try PeekSource.load(root: driveRoot, tempDir: tmp)

    #expect(ctx.items.count == 1)
    let item = try #require(ctx.items.first)
    #expect(item.thumbHash.stringValue == driveHash)           // real asset hash, not synthetic
    #expect(item.sourceURL.path.contains("Pictures/rome/IMG_1.jpg"))   // full-res from the drive
    // The load built its OWN temp catalog under tempDir (nothing written to any live catalog).
    #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("catalog.sqlite").path))
    #expect(ctx.thumbnails.cacheURL(for: item.thumbHash).path.hasPrefix(tmp.path))
}

// MARK: - synthetic hash

@Test func syntheticHashIsDeterministicAndPerPath() throws {
    let h1 = PeekSource.syntheticHash(forPath: "/a/b/c.jpg")
    let h2 = PeekSource.syntheticHash(forPath: "/a/b/c.jpg")
    let h3 = PeekSource.syntheticHash(forPath: "/a/b/d.jpg")
    #expect(h1 == h2)
    #expect(h1 != h3)
    #expect(h1.stringValue.hasPrefix("sha256:"))
}
