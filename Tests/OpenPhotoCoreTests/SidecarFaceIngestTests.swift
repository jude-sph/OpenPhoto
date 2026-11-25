import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

/// Confirmed person assignments live durably in XMP sidecars (`mwg-rs:Regions`). A catalog rebuilt
/// from scratch (deleted catalog, new Mac, switched library root) must reconstitute them on ingest.

private func makeLib(_ t: TestDirs, appSupport: String = "appsupport") throws -> LibraryService {
    try LibraryService(vaultRoots: [t.root.appendingPathComponent("Pictures")],
                       appSupportDir: try t.sub(appSupport))
}

private func writeSidecar(_ t: TestDirs, _ rel: String, faces: [FaceRegion]) throws {
    try t.file("Pictures/rome/.openphoto/\(rel).xmp",
               Data(XMP.serialize(SidecarData(rating: 0, favorite: false, caption: nil,
                                              tags: [], faces: faces)).utf8))
}

private func photoAsset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

private let aliceRect = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.3)
private let bobRect   = CGRect(x: 0.6, y: 0.2, width: 0.15, height: 0.2)

private func approx(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-5 && abs(a.minY - b.minY) < 1e-5
        && abs(a.width - b.width) < 1e-5 && abs(a.height - b.height) < 1e-5
}

@Test func freshCatalogReconstitutesNamedPeopleFromSidecars() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:08 14:23:01", lat: nil, lon: nil)
    try writeSidecar(t, "IMG_1.jpg", faces: [FaceRegion(name: "Alice", visionRect: aliceRect),
                                             FaceRegion(name: "Bob", visionRect: bobRect)])
    try writeSidecar(t, "IMG_2.jpg", faces: [FaceRegion(name: "Alice", visionRect: bobRect)])
    let lib = try makeLib(t)
    try await lib.scanAll()

    let people = try lib.catalog.people()
    #expect(Set(people.map(\.name)) == ["Alice", "Bob"])          // one row per name, not per region
    let alice = try #require(people.first { $0.name == "Alice" })
    #expect(alice.faceCount == 2)
    let h1 = try #require(try lib.items(inDir: "rome").first { $0.relPath.hasSuffix("IMG_1.jpg") }).hash
    let faces = try lib.catalog.faces(forHash: h1)
    #expect(faces.count == 2)
    #expect(faces.allSatisfy { $0.source == "confirmed" && $0.personID != nil && $0.embedding.isEmpty })
    let aliceFace = try #require(faces.first { $0.personID == alice.id })
    #expect(approx(aliceFace.rect, aliceRect))                     // exact inverse of the writer

    // Idempotent: a rescan (and a second one) adds nothing.
    try await lib.scanAll()
    try await lib.scanAll()
    #expect(try lib.catalog.people().count == 2)
    #expect(try lib.catalog.faces(forHash: h1).count == 2)
}

@Test func laterDetectionRefreshesRestoredFaceInsteadOfDuplicating() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    try writeSidecar(t, "IMG_1.jpg", faces: [FaceRegion(name: "Alice", visionRect: aliceRect)])
    let lib = try makeLib(t)
    try await lib.scanAll()
    let hash = try lib.items(inDir: "rome")[0].hash
    let vec = [Float](repeating: 0.044, count: FaceEmbedder.dimension)
    // The face stage later detects the same face (slightly different box) plus a stranger.
    try lib.catalog.replaceFaces(forHash: hash, with: [
        FaceRow(id: nil, hash: hash, rect: aliceRect.insetBy(dx: 0.005, dy: 0.005), embedding: vec,
                confidence: 0.9, source: "auto", personID: nil),
        FaceRow(id: nil, hash: hash, rect: bobRect, embedding: vec,
                confidence: 0.9, source: "auto", personID: nil),
    ])
    let faces = try lib.catalog.faces(forHash: hash)
    #expect(faces.count == 2)
    let named = try #require(faces.first { $0.source == "confirmed" })
    #expect(named.embedding.count == FaceEmbedder.dimension)       // embedding re-derived in place
    #expect(faces.filter { $0.source == "auto" }.count == 1)
    // And a rescan after detection still doesn't duplicate.
    try await lib.scanAll()
    #expect(try lib.catalog.faces(forHash: hash).count == 2)
}

@Test func sidecarRegionPromotesOverlappingAutoFaceAndNeverOverridesConfirmed() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photoAsset("h1")])
    let vec = [Float](repeating: 0.044, count: FaceEmbedder.dimension)
    let carol = try cat.createPerson(name: "Carol")
    _ = try cat.insertFaces([
        FaceRow(id: nil, hash: "h1", rect: aliceRect, embedding: vec, confidence: 0.9,
                source: "auto", personID: nil),
        FaceRow(id: nil, hash: "h1", rect: bobRect, embedding: vec, confidence: 0.9,
                source: "confirmed", personID: carol),
    ])
    try cat.applySidecarFaceRegions([
        "h1": [FaceRegion(name: "Alice", visionRect: aliceRect),
               FaceRegion(name: "Bob", visionRect: bobRect)],   // catalog says Carol here: keep Carol
        "unknown-hash": [FaceRegion(name: "Zed", visionRect: aliceRect)],
    ])
    let faces = try cat.faces(forHash: "h1")
    #expect(faces.count == 2)
    let people = try cat.people()
    #expect(Set(people.map(\.name)) == ["Alice", "Carol"])        // no Bob, no Zed created
    let alice = try #require(people.first { $0.name == "Alice" })
    let promoted = try #require(faces.first { approx($0.rect, aliceRect) })
    #expect(promoted.personID == alice.id && promoted.source == "confirmed")
    #expect(promoted.embedding.count == FaceEmbedder.dimension)   // kept the detected embedding
    #expect(faces.first { approx($0.rect, bobRect) }?.personID == carol)
}

@Test func fullImageRegionRestoresAsManualTag() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photoAsset("h1")])
    let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    try cat.applySidecarFaceRegions(["h1": [FaceRegion(name: "Dana", visionRect: full)]])
    try cat.applySidecarFaceRegions(["h1": [FaceRegion(name: "Dana", visionRect: full)]])
    let faces = try cat.faces(forHash: "h1")
    #expect(faces.count == 1)
    #expect(faces[0].source == "manual")
}
