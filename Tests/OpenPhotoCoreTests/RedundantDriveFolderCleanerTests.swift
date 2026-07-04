import Testing
import Foundation
@testable import OpenPhotoCore

// Helpers ---------------------------------------------------------------------

/// Write `bytes` at `rel` in `vault`, returning the content hash string.
@discardableResult
private func put(_ vault: Vault, _ rel: String, _ bytes: String) throws -> String {
    let url = vault.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url).stringValue
}

private func mEntry(_ rel: String, _ h: String) -> ManifestEntry {
    ManifestEntry(hash: ContentHash(stringValue: h), path: rel, size: 1,
                  mtime: "2024-01-01T00:00:00.000Z")
}
private func inst(_ vaultID: String, _ rel: String, _ h: String) -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: vaultID, relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 1, mtimeMs: 0)
}
private func pres(_ h: String, _ driveRel: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: h, relPath: driveRel,
                       dirPath: (driveRel as NSString).deletingLastPathComponent,
                       size: 1, driveRelPath: driveRel)
}

/// A drive vault + local vault + catalog with both registered.
private struct Rig {
    let drive: Vault, local: Vault, cat: Catalog
    init(_ t: TestDirs) throws {
        drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
        local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)
        cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
        try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
        try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    }
    func exists(_ v: Vault, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: v.absoluteURL(forRelativePath: rel).path)
    }
}

// Tests -----------------------------------------------------------------------

// PROOF: a folder whose every file has a byte-identical local copy is SAFE; each file's survivor is
// the verified local path.
@Test func assessProvesLocalSurvivorsAndIsSafe() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let hA = try put(r.drive, "Pics/stale/a.jpg", "AAAA")
    let hB = try put(r.drive, "Pics/stale/b.jpg", "BBBB")
    // Byte-identical local copies (elsewhere on the Mac) + catalog rows pointing at them.
    _ = try put(r.local, "album/a.jpg", "AAAA")
    _ = try put(r.local, "album/b.jpg", "BBBB")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", hA),
                                 inst(r.local.id, "album/b.jpg", hB)])

    let a = try RedundantDriveFolderCleaner.assess(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat)

    #expect(a.isSafe)
    #expect(a.blocked.isEmpty)
    #expect(Set(a.proven.map(\.driveRelPath)) == ["Pics/stale/a.jpg", "Pics/stale/b.jpg"])
    #expect(a.proven.allSatisfy { $0.survivor.hasPrefix("local:") })
}

// SAFETY: if even ONE file has no surviving copy anywhere, the folder is NOT safe — that file is
// blocked, and the rest are still reported proven (for transparency), but isSafe is false.
@Test func assessBlocksWhenAnyFileHasNoSurvivor() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let hA = try put(r.drive, "Pics/stale/a.jpg", "AAAA")
    _ = try put(r.drive, "Pics/stale/orphan.jpg", "ONLY-HERE")   // exists nowhere else
    _ = try put(r.local, "album/a.jpg", "AAAA")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", hA)])

    let a = try RedundantDriveFolderCleaner.assess(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat)

    #expect(!a.isSafe)
    #expect(a.blocked.map(\.driveRelPath) == ["Pics/stale/orphan.jpg"])
    #expect(a.proven.map(\.driveRelPath) == ["Pics/stale/a.jpg"])
}

// PROOF IS PHYSICAL, NOT CATALOG-TRUST: the catalog CLAIMS a local copy, but the physical local file's
// bytes differ (or it's missing). Must BLOCK — we verify the actual bytes, never the catalog's word.
@Test func assessDistrustsCatalogAndVerifiesBytes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let hA = try put(r.drive, "Pics/stale/a.jpg", "THE-REAL-CONTENT")
    // Catalog says a.jpg's content is local at album/a.jpg — but that file holds DIFFERENT bytes.
    _ = try put(r.local, "album/a.jpg", "DIFFERENT-CONTENT")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", hA)])   // lie: hash doesn't match file

    let a = try RedundantDriveFolderCleaner.assess(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat)

    #expect(!a.isSafe)
    #expect(a.blocked.map(\.driveRelPath) == ["Pics/stale/a.jpg"])
}

// ALL-OR-NOTHING: when blocked, removeIfProvenRedundant changes absolutely nothing on disk or catalog.
@Test func removeIsAllOrNothingWhenBlocked() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let hA = try put(r.drive, "Pics/stale/a.jpg", "AAAA")
    _ = try put(r.drive, "Pics/stale/orphan.jpg", "ONLY-HERE")
    _ = try put(r.local, "album/a.jpg", "AAAA")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", hA)])
    try Manifest.write([mEntry("Pics/stale/a.jpg", hA)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(hA, "Pics/stale/a.jpg")])

    let a = try RedundantDriveFolderCleaner.removeIfProvenRedundant(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(!a.isSafe)
    #expect(r.exists(r.drive, "Pics/stale/a.jpg"))         // nothing binned
    #expect(r.exists(r.drive, "Pics/stale/orphan.jpg"))
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/stale/a.jpg"])
    #expect(try r.cat.vaultPresenceHashes(forVault: r.drive.id) == [hA])
    #expect(try BinStore(vault: r.drive).list().isEmpty)   // bin untouched
}

// THE KEY CATALOG-SAFETY TEST: the same hash sits at BOTH the stale path and a surviving sibling path
// on the drive. Removal must delete presence BY PATH — the sibling's presence row (same hash) SURVIVES.
// (A by-hash delete, like the existing removeVaultPresence(hashes:), would wrongly erase the survivor.)
@Test func removeBinsFolderAndDropsPresenceByPathKeepingSharedHashSurvivor() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")   // stale copy
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")        // surviving sibling, same content
    _ = try put(r.local, "album/a.jpg", "SHARED")            // local ground truth
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", h)])
    try Manifest.write([mEntry("Pics/stale/a.jpg", h), mEntry("Pics/keep/a.jpg", h)],
                       to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [
        pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg")])

    let a = try RedundantDriveFolderCleaner.removeIfProvenRedundant(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(a.isSafe)
    // Stale copy binned (recoverable), sibling + local untouched.
    #expect(!r.exists(r.drive, "Pics/stale/a.jpg"))
    #expect(FileManager.default.fileExists(
        atPath: r.drive.binDirURL.appendingPathComponent("Pics/stale/a.jpg").path))
    #expect(try BinStore(vault: r.drive).list().first?.origin == .repaired)
    #expect(r.exists(r.drive, "Pics/keep/a.jpg"))
    #expect(r.exists(r.local, "album/a.jpg"))
    // Manifest keeps only the sibling.
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/keep/a.jpg"])
    // Presence: stale-path row gone, sibling row (SAME hash) survives — proves BY-PATH deletion.
    let rows = try r.cat.vaultPresenceRows(forVault: r.drive.id)
    #expect(rows.map(\.driveRelPath) == ["Pics/keep/a.jpg"])
    #expect(try r.cat.vaultPresenceHashes(forVault: r.drive.id) == [h])   // hash still present via sibling
    // Empty husk pruned.
    #expect(!FileManager.default.fileExists(
        atPath: r.drive.absoluteURL(forRelativePath: "Pics/stale").path))
}

// A folder file with NO local copy is still safe to remove if an identical sibling survives ON THE
// SAME DRIVE outside the folder (its bytes are physically verified). Survivor label is "drive:…".
@Test func assessProvesViaSameDriveSiblingWhenNoLocalCopy() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")   // sibling survivor, no local copy anywhere
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [
        pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg")])

    let a = try RedundantDriveFolderCleaner.assess(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat)

    #expect(a.isSafe)
    #expect(a.proven.map(\.driveRelPath) == ["Pics/stale/a.jpg"])
    #expect(a.proven.first?.survivor == "drive:Pics/keep/a.jpg")
}

// The sibling that proves safety must be OUTSIDE the folder. If a hash appears only twice INSIDE the
// folder (and nowhere else), neither copy can vouch for the other → blocked.
@Test func assessDoesNotCountAnInFolderDuplicateAsSurvivor() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "TWINS")
    _ = try put(r.drive, "Pics/stale/sub/a.jpg", "TWINS")   // duplicate, but also inside the folder
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [
        pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/stale/sub/a.jpg")])

    let a = try RedundantDriveFolderCleaner.assess(
        drive: r.drive, folderRelPath: "Pics/stale", localVault: r.local, catalog: r.cat)

    #expect(!a.isSafe)
    #expect(Set(a.blocked.map(\.driveRelPath)) == ["Pics/stale/a.jpg", "Pics/stale/sub/a.jpg"])
}
