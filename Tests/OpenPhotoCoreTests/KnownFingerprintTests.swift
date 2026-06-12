import Testing
import Foundation
@testable import OpenPhotoCore

/// `knownSizeDateKeys` powers the import grid's "already in your library anywhere" drive badge:
/// a size + capture-second fingerprint of every catalogued asset (local instances ∪ drive-only),
/// so a device photo can be flagged before it's downloaded (no hashing the device file).
@Test func knownSizeDateKeysCoversLocalAndDriveOnly() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    func asset(_ h: String, taken: Int64) -> AssetRecord {
        AssetRecord(hash: h, kind: "photo", takenAtMs: taken, pixelWidth: nil, pixelHeight: nil,
            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
            livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
            caption: nil, tagsJSON: "[]")
    }
    let local = "sha256:" + String(repeating: "a", count: 64)
    let drive = "sha256:" + String(repeating: "b", count: 64)
    // capture times chosen so the millisecond remainder is dropped: 123400 ms → second 123
    try cat.upsert(assets: [asset(local, taken: 1_700_000_123_400),
                            asset(drive, taken: 1_700_000_999_000)])
    try cat.replaceInstances(inVault: "v", with: [InstanceRecord(hash: local, vaultID: "v",
        relPath: "x.jpg", dirPath: "", size: 5000, mtimeMs: 1)])
    try cat.replaceVaultPresence(vaultID: "d", entries: [VaultPresenceEntry(hash: drive,
        relPath: "y.jpg", dirPath: "", size: 8000, driveRelPath: "D/y.jpg")])

    let keys = try cat.knownSizeDateKeys()
    #expect(keys.contains("5000|1700000123"))     // local instance, capture-second granularity
    #expect(keys.contains("8000|1700000999"))     // drive-only asset is covered too
    #expect(!keys.contains("5000|1700000124"))    // a different second does not match
}
