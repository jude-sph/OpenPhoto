import Testing
import Foundation
@testable import OpenPhotoCore

/// Regression: a folder moved on the Mac must re-key cached drive presence onto the new path, or
/// drive-only originals keep counting under the old dirPath and the folder lingers as a phantom in
/// folderCounts (re-dragging it then throws `.missing` — the directory is gone on disk).
@Test func rewritePresenceMovesDriveOnlyAssetsOntoNewDir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    func asset(_ h: String) -> AssetRecord {
        AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
            livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
            caption: nil, tagsJSON: "[]")
    }
    let direct = "sha256:" + String(repeating: "a", count: 64)   // rome2022/x.jpg
    let nested = "sha256:" + String(repeating: "b", count: 64)   // rome2022/day1/y.jpg
    let other  = "sha256:" + String(repeating: "c", count: 64)   // paris/z.jpg (untouched)
    try cat.upsert(assets: [asset(direct), asset(nested), asset(other)])
    // Production shape: driveRelPath carries the drive basename prefix; relPath/dirPath are Mac-aligned.
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: direct, relPath: "rome2022/x.jpg", dirPath: "rome2022",
                           size: 1, driveRelPath: "OpenPhoto-drive/rome2022/x.jpg"),
        VaultPresenceEntry(hash: nested, relPath: "rome2022/day1/y.jpg", dirPath: "rome2022/day1",
                           size: 1, driveRelPath: "OpenPhoto-drive/rome2022/day1/y.jpg"),
        VaultPresenceEntry(hash: other, relPath: "paris/z.jpg", dirPath: "paris",
                           size: 1, driveRelPath: "OpenPhoto-drive/paris/z.jpg")])

    // Move rome2022 under trips → trips/rome2022.
    try cat.rewriteVaultPresencePaths(fromDir: "rome2022", toDir: "trips/rome2022")

    // folderCounts no longer shows the old path; the new nested path carries both moved assets.
    let counts = try cat.folderCounts()
    #expect(counts["rome2022"] == nil)            // phantom gone
    #expect(counts["rome2022/day1"] == nil)
    #expect(counts["trips/rome2022"] == 1)        // direct child
    #expect(counts["trips/rome2022/day1"] == 1)   // nested child
    #expect(counts["paris"] == 1)                 // sibling untouched

    // The drive-prefixed path (used to read full-res / rehydrate) follows the move, basename intact.
    let rows = Dictionary(uniqueKeysWithValues:
        try cat.vaultPresenceRows(forVault: "drive").map { ($0.hash, $0) })
    #expect(rows[direct]?.relPath == "trips/rome2022/x.jpg")
    #expect(rows[direct]?.dirPath == "trips/rome2022")
    #expect(rows[direct]?.driveRelPath == "OpenPhoto-drive/trips/rome2022/x.jpg")
    #expect(rows[nested]?.driveRelPath == "OpenPhoto-drive/trips/rome2022/day1/y.jpg")
    #expect(rows[other]?.relPath == "paris/z.jpg")   // untouched
}

/// A sibling whose name shares the moved folder's prefix ("rome2022b") must NOT be rewritten.
@Test func rewritePresenceDoesNotTouchPrefixSiblings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "d", count: 64)
    try cat.upsert(assets: [AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil,
        pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome2022b/w.jpg", dirPath: "rome2022b",
                           size: 1, driveRelPath: "OpenPhoto-drive/rome2022b/w.jpg")])
    try cat.rewriteVaultPresencePaths(fromDir: "rome2022", toDir: "trips/rome2022")
    #expect(try cat.folderCounts()["rome2022b"] == 1)   // prefix sibling intact
}
