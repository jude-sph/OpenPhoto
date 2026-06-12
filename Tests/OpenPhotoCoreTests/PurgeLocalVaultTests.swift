import Testing
import Foundation
@testable import OpenPhotoCore

private func makeCatalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

@Test func purgeLocalVaultRemovesItsInstancesRegistrationAndOrphanAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let hLocal = "sha256:" + String(repeating: "a", count: 64)   // only in the local vault
    let hShared = "sha256:" + String(repeating: "b", count: 64)  // also on a drive

    try c.upsert(assets: [asset(hLocal), asset(hShared)])
    try c.registerVault(id: "v-local", role: "local", rootPath: "/tmp/pics")
    try c.replaceInstances(inVault: "v-local", with: [
        InstanceRecord(hash: hLocal, vaultID: "v-local", relPath: "a.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
        InstanceRecord(hash: hShared, vaultID: "v-local", relPath: "b.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
    ])
    // hShared is also present on a drive vault, so it must survive the purge.
    try c.registerVault(id: "v-drive", role: "canonical", rootPath: "/Volumes/Canon")
    try c.replaceVaultPresence(vaultID: "v-drive", entries: [
        VaultPresenceEntry(hash: hShared, relPath: "b.jpg", dirPath: "",
                           size: 1, driveRelPath: "b.jpg")])

    try c.purgeLocalVault(id: "v-local")

    // Vault gone, its instances gone, its photos leave the timeline.
    #expect(try c.registeredVaults().contains { $0.id == "v-local" } == false)
    // hLocal is gone from timeline; hShared remains as a drive-only item.
    let timelineHashes = try Set(c.timelineItems().map(\.hash))
    #expect(!timelineHashes.contains(hLocal))
    // hLocal is fully orphaned → its asset row is GC'd; hShared survives (drive presence).
    #expect(try c.assetHashes() == [hShared])
    // The drive vault is untouched.
    #expect(try c.registeredVaults().contains { $0.id == "v-drive" })
}
