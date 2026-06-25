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

@Test func movePhotosUpdatesCatalogIncrementallyWithoutRescan() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg"])
    let items = try lib.items(inDir: "a")
    #expect(items.count == 1)
    let hash = items[0].hash

    let result = lib.movePhotos(items, toDir: "b")
    #expect(result.moved == ["a/x.jpg": "b/x.jpg"])
    #expect(result.failures.isEmpty)

    // Catalog follows IMMEDIATELY — no rescan needed (the move updated the instance in place).
    #expect(try lib.items(inDir: "a").isEmpty)
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])
    // The file and the manifest entry moved too (same hash, new path).
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    let manifest = try Manifest.read(from: vault.manifestURL)
    #expect(manifest.map(\.path) == ["b/x.jpg"])
    #expect(manifest.first?.hash.stringValue == hash)

    // Air-tight: a full rescan is now a NO-OP — the incremental update already matches disk+manifest.
    try await lib.rescan(vaultID: vault.descriptor.vaultID)
    #expect(try lib.items(inDir: "a").isEmpty)
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])
}

// The reconnect review's "Undo" primitive: revert a local move using the drive as truth.
@Test func revertLocalMoveMovesFileBackAndRepathsInstance() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try await makeLibrary(t, files: ["a/x.jpg"])
    _ = lib.movePhotos(try lib.items(inDir: "a"), toDir: "b")     // a/x.jpg -> b/x.jpg
    #expect(try lib.items(inDir: "b").map(\.relPath) == ["b/x.jpg"])

    try lib.revertLocalMove(from: "b/x.jpg", to: "a/x.jpg")

    #expect(try lib.items(inDir: "b").isEmpty)
    #expect(try lib.items(inDir: "a").map(\.relPath) == ["a/x.jpg"])
    #expect(FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "a/x.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: vault.absoluteURL(forRelativePath: "b/x.jpg").path))
}

// Drive-only photo: no local instance to move back, so revert is a safe no-op (drive untouched).
@Test func revertLocalMoveIsNoOpWhenNoLocalInstance() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, _) = try await makeLibrary(t, files: ["a/x.jpg"])
    try lib.revertLocalMove(from: "z/none.jpg", to: "a/none.jpg")   // no instance at z/none.jpg
    #expect(try lib.items(inDir: "a").map(\.relPath) == ["a/x.jpg"])   // untouched
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
        try Data(XMP.serialize(SidecarData.empty).utf8).write(to: sc)
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

// Part B guarantee: applying a move to a drive (rename + manifest patch, as the offline-op drain
// does on reconnect) leaves a drift scan CLEAN — no "unknown/new" file, no "missing". So a moved
// file is never surfaced as a fresh photo to adopt.
@Test func appliedDriveMoveLeavesDriftClean() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (_, drive) = try await makeLibrary(t, files: ["old/x.jpg"])  // stand-in "drive": manifest + file
    // The move the queue drain performs on the drive:
    _ = try VaultReorganizer.moveFile(in: drive, relPath: "old/x.jpg", intoDirRelPath: "new")
    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.unknown.isEmpty)        // the new-path file is NOT "unknown / adopt"
    #expect(report.missing.isEmpty)        // the old path is NOT "missing"
    #expect(report.changed.isEmpty)
    #expect(report.presentHashes.count == 1)
}
