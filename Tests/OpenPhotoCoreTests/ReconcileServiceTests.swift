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
