// Tests/OpenPhotoCoreTests/DriveOnlyBrowseTests.swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func catalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}
private func asset(_ c: Catalog, hash: String, takenAtMs: Int64) throws {
    try c.upsert(assets: [AssetRecord(hash: hash, kind: "photo", takenAtMs: takenAtMs,
        pixelWidth: 4, pixelHeight: 4, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
}

@Test func driveOnlyAssetAppearsInTimeline() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try catalog(t)
    let h = "sha256:" + String(repeating: "d", count: 64)
    try asset(c, hash: h, takenAtMs: 1000)
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 9,
                           driveRelPath: "Pictures/rome/a.jpg")])
    let items = try c.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].hash == h && items[0].driveRelPath == "Pictures/rome/a.jpg")
    #expect(items[0].vaultID == "v-canon" && items[0].dirPath == "rome")
}

@Test func assetOnBothMacAndDriveShowsOnceAsLocal() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try catalog(t)
    let h = "sha256:" + String(repeating: "e", count: 64)
    try asset(c, hash: h, takenAtMs: 1000)
    try c.replaceInstances(inVault: "v-local", with: [
        InstanceRecord(hash: h, vaultID: "v-local", relPath: "rome/a.jpg", dirPath: "rome",
                       size: 9, mtimeMs: 0)])
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 9,
                           driveRelPath: "Pictures/rome/a.jpg")])
    let items = try c.timelineItems()
    #expect(items.count == 1)
    #expect(items[0].vaultID == "v-local" && items[0].driveRelPath == nil)  // local wins, full-res
}

@Test func driveOnlyAssetLandsInItsMacFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try catalog(t)
    let h = "sha256:" + String(repeating: "f", count: 64)
    try asset(c, hash: h, takenAtMs: 1000)
    try c.replaceVaultPresence(vaultID: "v-canon", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 9,
                           driveRelPath: "Pictures/rome/a.jpg")])
    #expect(try c.folderCounts()["rome"] == 1)
    #expect(try c.items(inDir: "rome").map(\.hash) == [h])
}

@Test func driveOnlyAssetOnTwoDrivesShowsOnce() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try catalog(t)
    let h = "sha256:" + String(repeating: "c", count: 64)
    try asset(c, hash: h, takenAtMs: 1000)
    // Same asset present on two drives, no local copy → must appear exactly once (MIN(rowid) dedup).
    try c.replaceVaultPresence(vaultID: "v-drive1", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 9,
                           driveRelPath: "Pictures/rome/a.jpg")])
    try c.replaceVaultPresence(vaultID: "v-drive2", entries: [
        VaultPresenceEntry(hash: h, relPath: "rome/a.jpg", dirPath: "rome", size: 9,
                           driveRelPath: "Pictures/rome/a.jpg")])
    #expect(try c.timelineItems().count == 1)
    #expect(try c.folderCounts()["rome"] == 1)
}
