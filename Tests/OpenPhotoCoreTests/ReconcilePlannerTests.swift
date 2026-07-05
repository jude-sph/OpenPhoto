import Testing
import Foundation
@testable import OpenPhotoCore

// ReconcilePlanner is the production adapter: it builds DESIRED (the library's placements, mapped to
// drive paths the same way sync does) and ACTUAL (the drive manifest) and returns a ReconcilePlan.
// Semantics are deliberately CONSERVATIVE: a drive placement with no local instance is treated as a
// retained evicted original (never proposed for deletion) — genuine-deletion detection stays with the
// existing deletion path. So reconcile here only ever copies/relocates/removes-stale.

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
private func inst(_ vaultID: String, _ rel: String, _ h: String) -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: vaultID, relPath: rel, dirPath: (rel as NSString).deletingLastPathComponent, size: 1, mtimeMs: 0)
}
private func pres(_ h: String, _ driveRel: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: h, relPath: driveRel, dirPath: (driveRel as NSString).deletingLastPathComponent, size: 1, driveRelPath: driveRel)
}
private struct Rig {
    let drive: Vault, local: Vault, cat: Catalog, base: String
    init(_ t: TestDirs) throws {
        drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
        local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)   // basename "mac"
        cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
        base = local.rootURL.lastPathComponent
        try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
        try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    }
    func d(_ rel: String) -> String { base + "/" + rel }   // local relPath -> drive path
}

// A drive that already mirrors the library yields an empty plan (idempotence, end to end).
@Test func plannerEmptyWhenDriveMirrorsLibrary() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "a/1.jpg", "one")
    try r.cat.upsert(instances: [inst(r.local.id, "a/1.jpg", h)])
    try Manifest.write([mEntry(r.d("a/1.jpg"), h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, r.d("a/1.jpg"))])

    #expect(try ReconcilePlanner.plan(drive: r.drive, localVault: r.local, catalog: r.cat).isEmpty)
}

// A stale extra copy on the drive (content also at the desired path) → stale removal.
@Test func plannerFindsStalePhantom() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "a/1.jpg", "one")
    try r.cat.upsert(instances: [inst(r.local.id, "a/1.jpg", h)])
    try Manifest.write([mEntry(r.d("a/1.jpg"), h), mEntry(r.d("old/1.jpg"), h)], to: r.drive.manifestURL)

    let plan = try ReconcilePlanner.plan(drive: r.drive, localVault: r.local, catalog: r.cat)
    #expect(plan.staleRemovals == [Placement(hash: h, path: r.d("old/1.jpg"))])
    #expect(plan.copies.isEmpty && plan.relocations.isEmpty && plan.reviewDeletions.isEmpty)
}

// A library file the drive lacks → copy.
@Test func plannerFindsMissingAsCopy() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h1 = try put(r.local, "a/1.jpg", "one"); let h2 = try put(r.local, "b/2.jpg", "two")
    try r.cat.upsert(instances: [inst(r.local.id, "a/1.jpg", h1), inst(r.local.id, "b/2.jpg", h2)])
    try Manifest.write([mEntry(r.d("a/1.jpg"), h1)], to: r.drive.manifestURL)   // missing b/2

    let plan = try ReconcilePlanner.plan(drive: r.drive, localVault: r.local, catalog: r.cat)
    #expect(plan.copies == [Placement(hash: h2, path: r.d("b/2.jpg"))])
    #expect(plan.staleRemovals.isEmpty && plan.relocations.isEmpty)
}

// A library file moved (drive still has the old path) → relocation.
@Test func plannerFindsMoveAsRelocation() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "new/1.jpg", "one")
    try r.cat.upsert(instances: [inst(r.local.id, "new/1.jpg", h)])
    try Manifest.write([mEntry(r.d("old/1.jpg"), h)], to: r.drive.manifestURL)

    let plan = try ReconcilePlanner.plan(drive: r.drive, localVault: r.local, catalog: r.cat)
    #expect(plan.relocations == [ReconcilePlan.Relocation(hash: h, from: r.d("old/1.jpg"), to: r.d("new/1.jpg"))])
    #expect(plan.copies.isEmpty && plan.staleRemovals.isEmpty)
}

// CONSERVATIVE: a drive placement with no local instance (an evicted original) is treated as desired
// and kept — never proposed as a deletion.
@Test func plannerKeepsEvictedOriginalNeverDeletes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    // A normal local-backed file, plus a drive-only (evicted) original with no local instance.
    let h = try put(r.local, "a/1.jpg", "one")
    try r.cat.upsert(instances: [inst(r.local.id, "a/1.jpg", h)])
    let evicted = "sha256:" + String(repeating: "e", count: 64)
    try Manifest.write([mEntry(r.d("a/1.jpg"), h), mEntry(r.d("evicted/x.jpg"), evicted)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, r.d("a/1.jpg")), pres(evicted, r.d("evicted/x.jpg"))])

    let plan = try ReconcilePlanner.plan(drive: r.drive, localVault: r.local, catalog: r.cat)
    #expect(plan.isEmpty)   // evicted original desired-and-present → no-op; NOT a deletion
}
