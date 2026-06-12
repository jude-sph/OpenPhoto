import Testing
import Foundation
@testable import OpenPhotoCore

/// Library over one temp vault with scanned JPEGs at the given relPaths.
/// Distinct EXIF dates → distinct bytes → distinct hashes.
private func makeLibrary(_ t: TestDirs, files: [String]) async throws -> (LibraryService, Vault) {
    let root = try t.sub("vault")
    for (i, rel) in files.enumerated() {
        try makeJPEG(at: root.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:10:07 14:23:0\(i)", lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [root], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    return (lib, lib.vaults[0])
}

@Test func movePhotosMovesFileAndCatalogFollowsAfterRescan() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg"])
    let items = try lib.items(inDir: "a")
    #expect(items.count == 1)

    let result = lib.movePhotos(items, toDir: "b")

    #expect(result.moved == ["a/x.jpg": "b/x.jpg"])
    #expect(result.failures.isEmpty)
    try await lib.rescan(vaultID: vault.descriptor.vaultID)
    #expect(try lib.items(inDir: "a").isEmpty)
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])
}

@Test func movePhotosCarriesLivePairPartnerWithSidecars() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    // Two scanned assets; we declare them a Live pair in the catalog (the carry logic
    // only follows livePairHash — media kind is irrelevant to the move mechanics).
    let (lib, vault) = try await makeLibrary(t, files: ["a/IMG_1.jpg", "a/IMG_1X.jpg"])
    let pre = try lib.items(inDir: "a")
    let photoHash = pre.first { $0.relPath == "a/IMG_1.jpg" }!.hash
    let videoHash = pre.first { $0.relPath == "a/IMG_1X.jpg" }!.hash
    try lib.catalog.setLivePair(photoHash: photoHash, videoHash: videoHash)
    // Sidecars for both halves.
    for rel in ["a/IMG_1.jpg", "a/IMG_1X.jpg"] {
        let sc = vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel))
        try FileManager.default.createDirectory(at: sc.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("xmp".utf8).write(to: sc)
    }
    // Re-fetch: the partner is now hidden; the photo row carries livePairHash.
    let item = try #require(try lib.items(inDir: "a").first { $0.hash == photoHash })
    #expect(item.livePairHash == videoHash)

    let result = lib.movePhotos([item], toDir: "b")

    #expect(result.moved["a/IMG_1.jpg"] == "b/IMG_1.jpg")
    #expect(result.moved["a/IMG_1X.jpg"] == "b/IMG_1X.jpg")   // partner traveled
    for rel in ["b/IMG_1.jpg", "b/IMG_1X.jpg"] {
        #expect(FileManager.default.fileExists(
            atPath: vault.absoluteURL(forRelativePath: rel).path))
        #expect(FileManager.default.fileExists(
            atPath: vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: rel)).path))
    }
    try await lib.rescan(vaultID: vault.descriptor.vaultID)
    #expect(try lib.items(inDir: "b").count == 1)   // pair shows as one browse row
}

@Test func movePhotosSkipsInDestCollectsFailuresAndContinues() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg", "a/y.jpg", "b/z.jpg"])
    // Make a/x.jpg vanish behind the catalog's back.
    try FileManager.default.removeItem(at: vault.absoluteURL(forRelativePath: "a/x.jpg"))
    let items = try lib.items(inDir: "a") + (try lib.items(inDir: "b"))

    let result = lib.movePhotos(items, toDir: "b")

    #expect(result.moved == ["a/y.jpg": "b/y.jpg"])          // z already in dest → skipped
    #expect(result.failures.keys.contains("a/x.jpg"))         // vanished → failure, batch continued
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/z.jpg").path))
}
