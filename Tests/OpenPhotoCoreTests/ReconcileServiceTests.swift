import Testing
import Foundation
@testable import OpenPhotoCore

// ReconcileService is the one-call integration point the app will invoke on reconnect: plan → apply →
// project presence from the reconciled manifest. This test drives it end to end and checks that
// presence becomes a faithful projection of the (now-mirrored) manifest.

@discardableResult
private func put(_ v: Vault, _ rel: String, _ bytes: String) throws -> String {
    let url = v.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url).stringValue
}
private func mEntry(_ rel: String, _ h: String) -> ManifestEntry {
    ManifestEntry(hash: ContentHash(stringValue: h), path: rel, size: 1, mtime: "2024-01-01T00:00:00.000Z")
}
private func pres(_ h: String, _ driveRel: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: h, relPath: driveRel, dirPath: (driveRel as NSString).deletingLastPathComponent, size: 1, driveRelPath: driveRel)
}

@Test func reconcileServiceAppliesPlanAndProjectsPresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    let base = local.rootURL.lastPathComponent

    // Library: a/1.jpg. Drive: the right copy + a stale phantom + a missing file to copy in.
    let h1 = try put(local, "a/1.jpg", "one")
    let h2 = try put(local, "b/2.jpg", "two")               // library has it; drive is missing it
    try cat.upsert(instances: [
        InstanceRecord(hash: h1, vaultID: local.id, relPath: "a/1.jpg", dirPath: "a", size: 1, mtimeMs: 0),
        InstanceRecord(hash: h2, vaultID: local.id, relPath: "b/2.jpg", dirPath: "b", size: 1, mtimeMs: 0),
    ])
    _ = try put(drive, "\(base)/a/1.jpg", "one")
    _ = try put(drive, "\(base)/old/1.jpg", "one")           // phantom stale copy
    try Manifest.write([mEntry("\(base)/a/1.jpg", h1), mEntry("\(base)/old/1.jpg", h1)], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.id, entries: [pres(h1, "\(base)/a/1.jpg"), pres(h1, "\(base)/old/1.jpg")])

    let res = try ReconcileService.reconcile(drive: drive, localVault: local, catalog: cat,
                                             sourceBasenames: [base], macVaultID: "mac")

    #expect(res.staleRemoved == 1)     // old/1.jpg phantom removed
    #expect(res.copied == 1)           // b/2.jpg copied in
    // Manifest now mirrors the library exactly.
    #expect(Set(try Manifest.read(from: drive.manifestURL).map(\.path)) == ["\(base)/a/1.jpg", "\(base)/b/2.jpg"])
    // Presence is a faithful projection: Mac-aligned relPath, drive-prefixed driveRelPath.
    let rows = try cat.vaultPresenceRows(forVault: drive.id).sorted { $0.relPath < $1.relPath }
    #expect(rows.map(\.relPath) == ["a/1.jpg", "b/2.jpg"])
    #expect(rows.map(\.driveRelPath) == ["\(base)/a/1.jpg", "\(base)/b/2.jpg"])
    // Re-running reconcile is a no-op (idempotent).
    let again = try ReconcileService.reconcile(drive: drive, localVault: local, catalog: cat,
                                               sourceBasenames: [base], macVaultID: "mac")
    #expect(again.staleRemoved == 0 && again.copied == 0 && again.relocated == 0 && again.deletionsApplied == 0)
}

// An evicted (drive-only) photo moved on the Mac while the drive was offline: the move re-keys the
// drive's presence row (relPath = new Mac folder, driveRelPath = where the bytes still are) and queues an
// op. Reconnect reconcile must carry the move to the drive — not rebuild presence from the old manifest
// path and silently revert it (the op queue is cleared right after).
@Test func reconcileCarriesOfflineMoveOfEvictedPhoto() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    let base = local.rootURL.lastPathComponent

    let h = try put(drive, "\(base)/a/1.jpg", "evicted")      // only on the drive
    let k = try put(drive, "\(base)/a/2.jpg", "untouched")    // evicted, not moved
    try Manifest.write([mEntry("\(base)/a/1.jpg", h), mEntry("\(base)/a/2.jpg", k)], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.id, entries: [
        VaultPresenceEntry(hash: h, relPath: "a/1.jpg", dirPath: "a", size: 1, driveRelPath: "\(base)/a/1.jpg"),
        VaultPresenceEntry(hash: k, relPath: "a/2.jpg", dirPath: "a", size: 1, driveRelPath: "\(base)/a/2.jpg")])
    // Offline move a/1.jpg → b/1.jpg, as AppState.movePhotos does for a drive-only item.
    try cat.rewriteVaultPresencePath(vaultID: drive.id, fromRelPath: "a/1.jpg", toRelPath: "b/1.jpg")
    try cat.enqueueFolderOp(vaultID: drive.id, op: "moveFile", src: "a/1.jpg", dst: "b/1.jpg")

    let res = try ReconcileService.reconcile(drive: drive, localVault: local, catalog: cat,
                                             sourceBasenames: [base], macVaultID: "mac")
    #expect(res.relocated == 1 && res.staleRemoved == 0 && res.deletionsApplied == 0)
    #expect(Set(try Manifest.read(from: drive.manifestURL).map(\.path)) == ["\(base)/b/1.jpg", "\(base)/a/2.jpg"])
    #expect(FileManager.default.fileExists(atPath: drive.absoluteURL(forRelativePath: "\(base)/b/1.jpg").path))
    let rows = try cat.vaultPresenceRows(forVault: drive.id).sorted { $0.relPath < $1.relPath }
    #expect(rows.map(\.relPath) == ["a/2.jpg", "b/1.jpg"])     // the Mac's move survived
    let again = try ReconcileService.reconcile(drive: drive, localVault: local, catalog: cat,
                                               sourceBasenames: [base], macVaultID: "mac")
    #expect(again.relocated == 0 && again.copied == 0 && again.staleRemoved == 0)
}

// Same, for a whole folder moved offline (presence re-keyed by directory).
@Test func reconcileCarriesOfflineFolderMoveOfEvictedPhotos() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
    try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    let base = local.rootURL.lastPathComponent
    let h = try put(drive, "\(base)/trip/1.jpg", "evicted")
    try Manifest.write([mEntry("\(base)/trip/1.jpg", h)], to: drive.manifestURL)
    try cat.replaceVaultPresence(vaultID: drive.id, entries: [
        VaultPresenceEntry(hash: h, relPath: "trip/1.jpg", dirPath: "trip", size: 1, driveRelPath: "\(base)/trip/1.jpg")])
    try cat.rewriteVaultPresencePaths(fromDir: "trip", toDir: "2024/trip")
    try cat.enqueueFolderOp(vaultID: drive.id, op: "move", src: "trip", dst: "2024/trip")

    _ = try ReconcileService.reconcile(drive: drive, localVault: local, catalog: cat,
                                       sourceBasenames: [base], macVaultID: "mac")
    #expect(try Manifest.read(from: drive.manifestURL).map(\.path) == ["\(base)/2024/trip/1.jpg"])
    #expect(try cat.vaultPresenceRows(forVault: drive.id).map(\.relPath) == ["2024/trip/1.jpg"])
}
