import Testing
import Foundation
@testable import OpenPhotoCore

@Test func enqueueDequeueAndListRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let h2 = "sha256:" + String(repeating: "2", count: 64)

    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 100)
    try cat.enqueuePendingDeletion(hash: h2, relPath: "paris/IMG_2.jpg", deletedAtMs: 200)
    // Re-enqueue same hash updates, never duplicates (PK = hash).
    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 150)

    let all = try cat.pendingDeletions()
    #expect(all.count == 2)
    #expect(all.first?.hash == h2)                 // newest (deletedAtMs DESC)
    #expect(all.first(where: { $0.hash == h1 })?.deletedAtMs == 150)

    try cat.dequeuePendingDeletion(hash: h1)
    #expect(try cat.pendingDeletions().map(\.hash) == [h2])

    try cat.clearPendingDeletions(hashes: [h2])
    #expect(try cat.pendingDeletions().isEmpty)
    // Empty input is a no-op, never an error.
    try cat.clearPendingDeletions(hashes: [])
}

@Test func eligibilitySupportAccessors() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "mac", role: "local", rootPath: "/p")
    let still = "sha256:" + String(format: "%064d", 1)
    let video = "sha256:" + String(format: "%064d", 2)
    let photo = AssetRecord(hash: still, kind: "photo", takenAtMs: 0, pixelWidth: 1, pixelHeight: 1,
                            latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                            durationSeconds: nil, livePairHash: video, isLivePairedVideo: false,
                            favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [photo])
    try cat.upsert(instances: [InstanceRecord(hash: still, vaultID: "mac",
        relPath: "a/I.heic", dirPath: "a", size: 1, mtimeMs: 0)])

    #expect(try cat.instanceHashes() == [still])
    #expect(try cat.assetLivePairHash(forHash: still) == video)
    #expect(try cat.assetLivePairHash(forHash: video) == nil)

    // removeVaultPresence is targeted by (vaultID, hash) and no-ops on empty.
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: still, relPath: "a/I.heic", dirPath: "a", size: 1, driveRelPath: "Pictures/a/I.heic"),
        VaultPresenceEntry(hash: video, relPath: "a/I.mov", dirPath: "a", size: 1, driveRelPath: "Pictures/a/I.mov"),
    ])
    try cat.removeVaultPresence(vaultID: "drive", hashes: [still])
    #expect(try cat.vaultPresenceHashes(forVault: "drive") == [video])
    try cat.removeVaultPresence(vaultID: "drive", hashes: [])   // no-op
    #expect(try cat.vaultPresenceHashes(forVault: "drive") == [video])
    _ = photo
}
