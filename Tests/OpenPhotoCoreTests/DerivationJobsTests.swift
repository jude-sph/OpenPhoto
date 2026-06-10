import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String, takenAtMs: Int64 = 1) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}
private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)
private let C = "sha256:" + String(repeating: "c", count: 64)

@Test func pendingDerivationLifecycle() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A, takenAtMs: 3), photo(B, takenAtMs: 2), photo(C, takenAtMs: 1)])

    // All three pending initially (newest-first).
    #expect(try cat.pendingDerivation(stage: "ocr") == [A, B, C])

    // Marking A done removes it from pending.
    try cat.markDerived(hash: A, stage: "ocr")
    #expect(try cat.pendingDerivation(stage: "ocr") == [B, C])

    // A failure keeps B pending (retryable) until the attempt cap.
    try cat.markDerivationFailed(hash: B, stage: "ocr")   // attempts = 1
    #expect(try cat.pendingDerivation(stage: "ocr").contains(B))
    try cat.markDerivationFailed(hash: B, stage: "ocr")   // 2
    try cat.markDerivationFailed(hash: B, stage: "ocr")   // 3 → at cap, excluded
    #expect(!(try cat.pendingDerivation(stage: "ocr").contains(B)))
    #expect(try cat.pendingDerivation(stage: "ocr") == [C])

    // Progress: 1 of 3 done (A); B is failed-over-cap but not "done".
    let p = try cat.derivationProgress(stage: "ocr")
    #expect(p.total == 3 && p.done == 1)
}

@Test func ocrStoreAndSearch() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsertOCR(hash: A, text: "a sign that says PARKING garage")
    try cat.upsertOCR(hash: B, text: "menu with COFFEE and tea")

    #expect(try cat.searchOCR("parking") == [A])
    #expect(try cat.searchOCR("coffee") == [B])
    #expect(try cat.searchOCR("zzzznothing").isEmpty)
    // upsert replaces (no duplicate rows): re-set A's text, old term no longer matches.
    try cat.upsertOCR(hash: A, text: "now it says EXIT only")
    #expect(try cat.searchOCR("parking").isEmpty)
    #expect(try cat.searchOCR("exit") == [A])
}

@Test func videosAreNotOCREligible() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let vid = photo(A); // build a video record
    try cat.upsert(assets: [AssetRecord(hash: A, kind: "video", takenAtMs: 1, pixelWidth: nil,
        pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: 5, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")])
    _ = vid
    #expect(try cat.pendingDerivation(stage: "ocr").isEmpty)        // videos skipped for OCR
    #expect(try cat.derivationProgress(stage: "ocr").total == 0)
}
