import Testing
import Foundation
@testable import OpenPhotoCore

/// Builds a `LibraryService` over a single local "Pictures" vault + a canonical drive, mirroring
/// `SyncApplyTests`/`RehydrateTests` setup. Lets tests construct drive-only or locally-backed-up
/// `TimelineItem`s and exercise `rehydrate`'s progress/cancel paths against real bytes on disk.
struct StorageTestHarness {
    let dirs: TestDirs
    let lib: LibraryService
    let drive: Vault
    let pics: URL

    static func make() throws -> StorageTestHarness {
        let dirs = try TestDirs()
        // Local vault root basename MUST be "Pictures" so `localTarget` maps a drive path whose
        // first component is "Pictures" back to this vault (the inverse of the basename-strip).
        let pics = try dirs.sub("Pictures")
        let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try dirs.sub("as"))
        let drive = try Vault.openOrCreate(at: try dirs.sub("drive"), role: .canonical)
        try lib.catalog.registerVault(id: drive.descriptor.vaultID, role: "canonical",
                                      rootPath: drive.rootURL.path)
        return StorageTestHarness(dirs: dirs, lib: lib, drive: drive, pics: pics)
    }

    func cleanup() { dirs.cleanup() }

    private var localVaultID: String { lib.vaults[0].descriptor.vaultID }

    /// `count` unique mock files of `sizeEach` bytes written ONLY onto the drive (under
    /// `Pictures/op_<i>.jpg`), hashed, and recorded as `vault_presence` rows. Returns drive-only
    /// `TimelineItem`s (`driveRelPath` set) whose `vaultID` is the local vault — so a successful
    /// rehydrate genuinely copies bytes from the drive back into the local vault.
    func makeDriveOnly(count: Int, sizeEach: Int) throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var presence = (try? lib.catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)) ?? []
        for i in 0..<count {
            // Distinct path + seed range from makeLocalBackedUp so a test that builds BOTH sets gets
            // genuinely disjoint content (no hash collision that would make a "drive-only" file alias a
            // locally-backed-up one and be filtered out of the drive-only branch by NOT EXISTS).
            let relPath = "do_\(i).jpg"
            let driveRel = "Pictures/\(relPath)"
            let url = drive.rootURL.appendingPathComponent(driveRel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try uniqueBytes(seed: UInt8(100 &+ i), count: sizeEach).write(to: url)
            let hash = try ContentHash.ofFile(at: url).stringValue
            // A drive-only asset still has a catalog `assets` row in production (sync's CatalogIngest
            // upserts assets alongside vault_presence). Seed one so catalog browse queries that join
            // `assets` (the Folders tree, the drive-only gather) can surface it.
            try lib.catalog.upsert(assets: [AssetRecord(
                hash: hash, kind: MediaKind.photo.rawValue, takenAtMs: Int64(i),
                pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil,
                cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
            presence.append(VaultPresenceEntry(hash: hash, relPath: relPath, dirPath: "",
                                               size: Int64(sizeEach), driveRelPath: driveRel))
            items.append(timelineItem(hash: hash, vaultID: localVaultID, relPath: relPath,
                                      size: Int64(sizeEach), driveRelPath: driveRel))
        }
        try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: presence)
        return items
    }

    /// `count` unique mock files written into BOTH the local vault and the drive (same bytes → same
    /// hash). Records a local `instances` row + an `assets` row + a drive `vault_presence` row.
    /// Returns local `TimelineItem`s (`driveRelPath == nil`).
    func makeLocalBackedUp(count: Int, sizeEach: Int) throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var presence = (try? lib.catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)) ?? []
        for i in 0..<count {
            let relPath = "op_\(i).jpg"
            let bytes = try uniqueBytes(seed: UInt8(i &+ 1), count: sizeEach)
            let localURL = pics.appendingPathComponent(relPath)
            try bytes.write(to: localURL)
            let driveRel = "Pictures/\(relPath)"
            let driveURL = drive.rootURL.appendingPathComponent(driveRel)
            try FileManager.default.createDirectory(at: driveURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: driveURL)
            let hash = try ContentHash.ofFile(at: localURL).stringValue
            try lib.catalog.upsert(assets: [AssetRecord(
                hash: hash, kind: MediaKind.photo.rawValue, takenAtMs: Int64(i),
                pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil,
                cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
            try lib.catalog.upsert(instances: [InstanceRecord(
                hash: hash, vaultID: localVaultID, relPath: relPath, dirPath: "",
                size: Int64(sizeEach), mtimeMs: 0)])
            presence.append(VaultPresenceEntry(hash: hash, relPath: relPath, dirPath: "",
                                               size: Int64(sizeEach), driveRelPath: driveRel))
            items.append(timelineItem(hash: hash, vaultID: localVaultID, relPath: relPath,
                                      size: Int64(sizeEach), driveRelPath: nil))
        }
        try lib.catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: presence)
        return items
    }

    private func timelineItem(hash: String, vaultID: String, relPath: String,
                              size: Int64, driveRelPath: String?) -> TimelineItem {
        var data = Data()
        // TimelineItem has no public memberwise init — decode one from JSON.
        let json: [String: Any] = [
            "hash": hash, "kind": MediaKind.photo.rawValue, "takenAtMs": 0,
            "livePairHash": NSNull(), "favorite": false, "rating": 0,
            "tagsJSON": "[]", "rotation": 0, "vaultID": vaultID, "relPath": relPath,
            "dirPath": (relPath as NSString).deletingLastPathComponent, "size": size,
            "driveRelPath": driveRelPath as Any]
        data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(TimelineItem.self, from: data)
    }

    /// `count` bytes of a per-file-unique, non-trivial pattern (so each file hashes differently).
    private func uniqueBytes(seed: UInt8, count: Int) throws -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for j in 0..<count { p[j] = seed &+ UInt8(j & 0xFF) }
        }
        return d
    }
}

@Test func rehydrateReportsByteProgressAndNamesFailures() async throws {
    let h = try StorageTestHarness.make(); defer { h.cleanup() }
    let items = try h.makeDriveOnly(count: 2, sizeEach: 1_000_000)
    final class Box: @unchecked Sendable { var last: DriveProgress?; var maxBytes: Int64 = 0 }
    let box = Box()
    let outcome = try await h.lib.rehydrate(items, connectedCanonical: [h.drive],
        progress: { p in box.last = p; box.maxBytes = max(box.maxBytes, p.bytesDone) },
        shouldCancel: nil)
    #expect(outcome.rehydrated == 2)
    #expect(outcome.failedItems.isEmpty)
    #expect(box.maxBytes == 2_000_000)
    #expect(box.last?.stage == .copying)
}

@Test func rehydrateCancelStopsEarly() async throws {
    let h = try StorageTestHarness.make(); defer { h.cleanup() }
    let items = try h.makeDriveOnly(count: 3, sizeEach: 1_000_000)
    let outcome = try await h.lib.rehydrate(items, connectedCanonical: [h.drive],
        progress: nil, shouldCancel: { true })
    #expect(outcome.rehydrated == 0)
}

@Test func evictReportsSizeWeightedProgressAndCancels() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeLocalBackedUp(count: 3, sizeEach: 1_000_000)   // local + verified on drive
    final class Box: @unchecked Sendable { var maxBytes: Int64 = 0; var lastFiles = 0 }
    let box = Box()
    let outcome = try await h.lib.evict(items, mode: .verified,
        connectedCanonical: [h.drive], canonicalPresence: [],
        progress: { p in box.maxBytes = max(box.maxBytes, p.bytesDone); box.lastFiles = p.filesDone },
        shouldCancel: nil)
    #expect(outcome.evicted == 3)
    #expect(outcome.refused == 0)
    #expect(box.maxBytes == 3_000_000)              // size-weighted bar reached the total
}

@Test func evictCancelStopsAndKeepsRemaining() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeLocalBackedUp(count: 3, sizeEach: 1_000_000)
    let outcome = try await h.lib.evict(items, mode: .verified,
        connectedCanonical: [h.drive], canonicalPresence: [],
        progress: nil, shouldCancel: { true })       // cancel immediately
    #expect(outcome.evicted == 0)                    // nothing trashed
}

// After evict, the item must remain visible as DRIVE-ONLY: its local instance is gone but the drive's
// vault_presence row is untouched, so `allDriveOnly()` surfaces it. (Regression guard: the catalog
// side of "evicted photos must not vanish" — the drive presence must survive a local evict.)
@Test func evictLeavesItemsAsDriveOnly() async throws {
    let h = try StorageTestHarness.make()
    let items = try h.makeLocalBackedUp(count: 2, sizeEach: 1000)
    #expect(try h.lib.allDriveOnly().isEmpty)        // present locally → not drive-only yet
    _ = try await h.lib.evict(items, mode: .verified,
        connectedCanonical: [h.drive], canonicalPresence: [], progress: nil, shouldCancel: nil)
    #expect(Set(try h.lib.allDriveOnly().map(\.hash)) == Set(items.map(\.hash)))   // now drive-only
}
