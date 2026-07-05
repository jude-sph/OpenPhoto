import Testing
import Foundation
@testable import OpenPhotoCore

// Phase 2 execution: applying a reconcile plan's stale-removals is DESTRUCTIVE, so it re-proves safety
// on disk (Decision 3): each file must hash to the expected value AND have a byte-verified surviving
// copy OUTSIDE the removal set before it's binned (recoverable). Genuine deletions are never
// auto-applied; a high deletion blast-radius blocks everything.

@discardableResult
private func put(_ vault: Vault, _ rel: String, _ bytes: String) throws -> String {
    let url = vault.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url).stringValue
}
private func mEntry(_ rel: String, _ h: String) -> ManifestEntry {
    ManifestEntry(hash: ContentHash(stringValue: h), path: rel, size: 1, mtime: "2024-01-01T00:00:00.000Z")
}
private func inst(_ vaultID: String, _ rel: String, _ h: String) -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: vaultID, relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 1, mtimeMs: 0)
}
private func pres(_ h: String, _ driveRel: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: h, relPath: driveRel, dirPath: (driveRel as NSString).deletingLastPathComponent,
                       size: 1, driveRelPath: driveRel)
}
private struct Rig {
    let drive: Vault, local: Vault, cat: Catalog
    init(_ t: TestDirs) throws {
        drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
        local = try Vault.openOrCreate(at: try t.sub("mac"), role: .local)
        cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
        try cat.registerVault(id: drive.descriptor.vaultID, role: "canonical", rootPath: drive.rootURL.path)
        try cat.registerVault(id: local.descriptor.vaultID, role: "local", rootPath: local.rootURL.path)
    }
    func onDrive(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: drive.absoluteURL(forRelativePath: rel).path) }
    func onLocal(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: local.absoluteURL(forRelativePath: rel).path) }
    func binned(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: drive.binDirURL.appendingPathComponent(rel).path) }
}
private func P(_ h: String, _ p: String) -> Placement { Placement(hash: h, path: p) }

// Verified stale removal: the file hashes right AND a local survivor exists → binned (.repaired);
// the survivor's presence row (SAME hash) is kept because presence is dropped BY PATH.
@Test func removesVerifiedStaleKeepingSharedHashSurvivor() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")     // desired-path copy (survivor)
    _ = try put(r.local, "album/a.jpg", "SHARED")         // local survivor
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", h)])
    try Manifest.write([mEntry("Pics/stale/a.jpg", h), mEntry("Pics/keep/a.jpg", h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg")])

    let res = try ReconcileExecutor.applyStaleRemovals([P(h, "Pics/stale/a.jpg")],
                    drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.RemovalResult(removed: 1, skipped: 0, alreadyGone: 0))
    #expect(!r.onDrive("Pics/stale/a.jpg") && r.binned("Pics/stale/a.jpg"))
    #expect(try BinStore(vault: r.drive).list().first?.origin == .repaired)
    #expect(r.onDrive("Pics/keep/a.jpg") && r.onLocal("album/a.jpg"))
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/keep/a.jpg"])
    #expect(try r.cat.vaultPresenceRows(forVault: r.drive.id).map(\.driveRelPath) == ["Pics/keep/a.jpg"])
    #expect(try r.cat.vaultPresenceHashes(forVault: r.drive.id) == [h])   // hash retained via survivor
}

// A same-drive sibling (no local copy) is a valid survivor.
@Test func survivorMayBeADriveSibling() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")
    try Manifest.write([mEntry("Pics/stale/a.jpg", h), mEntry("Pics/keep/a.jpg", h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg")])

    let res = try ReconcileExecutor.applyStaleRemovals([P(h, "Pics/stale/a.jpg")],
                    drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")
    #expect(res.removed == 1)
    #expect(r.onDrive("Pics/keep/a.jpg"))
}

// SAFETY: a stale-removal whose hash has NO verifiable survivor is SKIPPED, not removed — even though
// the plan listed it (defends against catalog/manifest drift).
@Test func skipsWhenNoSurvivorVerifiable() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/orphan.jpg", "ONLY-HERE")
    try Manifest.write([mEntry("Pics/stale/orphan.jpg", h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/orphan.jpg")])

    let res = try ReconcileExecutor.applyStaleRemovals([P(h, "Pics/stale/orphan.jpg")],
                    drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.RemovalResult(removed: 0, skipped: 1, alreadyGone: 0))
    #expect(r.onDrive("Pics/stale/orphan.jpg"))                                       // still there
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/stale/orphan.jpg"])
    #expect(try r.cat.vaultPresenceHashes(forVault: r.drive.id) == [h])
}

// SAFETY: if the file on disk no longer matches the hash we mean to remove (content changed under us),
// SKIP it — never bin a file we can't identify.
@Test func skipsWhenDiskContentDiffersFromPlan() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let realH = try put(r.drive, "Pics/keep/a.jpg", "SHARED")     // survivor with the target hash
    _ = try put(r.local, "album/a.jpg", "SHARED")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", realH)])
    // The "stale" path exists but holds DIFFERENT bytes than realH.
    _ = try put(r.drive, "Pics/stale/a.jpg", "SOMETHING-ELSE")
    try Manifest.write([mEntry("Pics/keep/a.jpg", realH), mEntry("Pics/stale/a.jpg", realH)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(realH, "Pics/keep/a.jpg"), pres(realH, "Pics/stale/a.jpg")])

    // Plan says remove the stale path as hash realH, but on disk it's not realH.
    let res = try ReconcileExecutor.applyStaleRemovals([P(realH, "Pics/stale/a.jpg")],
                    drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.RemovalResult(removed: 0, skipped: 1, alreadyGone: 0))
    #expect(r.onDrive("Pics/stale/a.jpg"))                                            // untouched
}

// A stale path already gone on disk is counted alreadyGone and cleared from manifest/presence (goal
// state reached) — not an error, not a removal.
@Test func alreadyGoneClearsRecordsWithoutBinning() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/keep/a.jpg", "SHARED")
    _ = try put(r.local, "album/a.jpg", "SHARED")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", h)])
    // Manifest/presence reference a stale path with no file on disk.
    try Manifest.write([mEntry("Pics/keep/a.jpg", h), mEntry("Pics/stale/ghost.jpg", h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/keep/a.jpg"), pres(h, "Pics/stale/ghost.jpg")])

    let res = try ReconcileExecutor.applyStaleRemovals([P(h, "Pics/stale/ghost.jpg")],
                    drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.RemovalResult(removed: 0, skipped: 0, alreadyGone: 1))
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/keep/a.jpg"])
    #expect(try r.cat.vaultPresenceRows(forVault: r.drive.id).map(\.driveRelPath) == ["Pics/keep/a.jpg"])
}

// Batch: several verified stale removals + a bystander → all removed in one pass, bystander untouched.
@Test func batchRemovesVerifiedAndLeavesBystander() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h1 = try put(r.drive, "Pics/staleA/1.jpg", "C1"); _ = try put(r.drive, "Pics/keep/1.jpg", "C1")
    let h2 = try put(r.drive, "Pics/staleB/2.jpg", "C2"); _ = try put(r.drive, "Pics/keep/2.jpg", "C2")
    let hb = try put(r.drive, "Pics/keep/bystander.jpg", "CB")
    for (rel, h) in [("album/1.jpg", h1), ("album/2.jpg", h2), ("album/b.jpg", hb)] {
        _ = try put(r.local, rel, rel == "album/1.jpg" ? "C1" : rel == "album/2.jpg" ? "C2" : "CB")
        try r.cat.upsert(instances: [inst(r.local.id, rel, h)])
    }
    try Manifest.write([mEntry("Pics/staleA/1.jpg", h1), mEntry("Pics/keep/1.jpg", h1),
                        mEntry("Pics/staleB/2.jpg", h2), mEntry("Pics/keep/2.jpg", h2),
                        mEntry("Pics/keep/bystander.jpg", hb)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [
        pres(h1, "Pics/staleA/1.jpg"), pres(h1, "Pics/keep/1.jpg"),
        pres(h2, "Pics/staleB/2.jpg"), pres(h2, "Pics/keep/2.jpg"),
        pres(hb, "Pics/keep/bystander.jpg")])

    let res = try ReconcileExecutor.applyStaleRemovals(
        [P(h1, "Pics/staleA/1.jpg"), P(h2, "Pics/staleB/2.jpg")],
        drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res.removed == 2)
    #expect(!r.onDrive("Pics/staleA/1.jpg") && !r.onDrive("Pics/staleB/2.jpg"))
    #expect(r.onDrive("Pics/keep/bystander.jpg"))
    #expect(Set(try Manifest.read(from: r.drive.manifestURL).map(\.path))
                == ["Pics/keep/1.jpg", "Pics/keep/2.jpg", "Pics/keep/bystander.jpg"])
}

// BLAST-RADIUS: a plan whose GENUINE deletions exceed the threshold blocks ALL destructive work
// (the catalog looks untrustworthy) and surfaces the deletions for review — nothing is touched.
@Test func applyBlocksEverythingWhenDeletionBlastRadiusTooHigh() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")
    let dgone = "sha256:" + String(repeating: "e", count: 64)
    _ = try put(r.drive, "Pics/x/gone.jpg", "GONE")
    try Manifest.write([mEntry("Pics/stale/a.jpg", h), mEntry("Pics/keep/a.jpg", h), mEntry("Pics/x/gone.jpg", dgone)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg"), pres(dgone, "Pics/x/gone.jpg")])

    let plan = ReconcilePlan(copies: [], relocations: [],
                             staleRemovals: [P(h, "Pics/stale/a.jpg")],
                             reviewDeletions: [P(dgone, "Pics/x/gone.jpg")])
    // 1 deletion over actualCount 3 = 0.33 > threshold 0.25 → blocked.
    let res = try ReconcileExecutor.apply(plan: plan, drive: r.drive, localVault: r.local, catalog: r.cat,
                                          actualCount: 3, macVaultID: "mac", maxDeletionFraction: 0.25)

    #expect(res.blockedByBlastRadius)
    #expect(res.staleRemoved == 0 && res.deletionsApplied == 0)
    #expect(res.blockedDeletions == [P(dgone, "Pics/x/gone.jpg")])
    #expect(r.onDrive("Pics/stale/a.jpg"))                                            // nothing touched
}

// apply() runs stale-removals AND honors genuine deletions (bins the drive copy) when the blast-radius
// is fine — a delete on the Mac propagates to the drive.
@Test func applyRunsStaleRemovalsAndHonorsDeletions() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/a.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/a.jpg", "SHARED")
    _ = try put(r.local, "album/a.jpg", "SHARED")
    try r.cat.upsert(instances: [inst(r.local.id, "album/a.jpg", h)])
    let dgone = try put(r.drive, "Pics/x/gone.jpg", "GONE")     // real hash of the deleted file
    try Manifest.write([mEntry("Pics/stale/a.jpg", h), mEntry("Pics/keep/a.jpg", h), mEntry("Pics/x/gone.jpg", dgone)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/a.jpg"), pres(h, "Pics/keep/a.jpg"), pres(dgone, "Pics/x/gone.jpg")])

    let plan = ReconcilePlan(copies: [], relocations: [],
                             staleRemovals: [P(h, "Pics/stale/a.jpg")],
                             reviewDeletions: [P(dgone, "Pics/x/gone.jpg")])
    let res = try ReconcileExecutor.apply(plan: plan, drive: r.drive, localVault: r.local, catalog: r.cat,
                                          actualCount: 100, macVaultID: "mac")   // 1/100 deletions → fine

    #expect(!res.blockedByBlastRadius)
    #expect(res.staleRemoved == 1 && res.deletionsApplied == 1)
    #expect(!r.onDrive("Pics/stale/a.jpg"))                     // stale removed
    #expect(!r.onDrive("Pics/x/gone.jpg"))                      // deletion honored → binned (recoverable)
    #expect(FileManager.default.fileExists(atPath: r.drive.binDirURL.appendingPathComponent("Pics/x/gone.jpg").path))
}

// After removals empty a folder, its husk is pruned — but a non-empty ancestor (still holding other
// media) is never touched. No empty phantom folders left behind on the drive.
@Test func prunesEmptiedHuskKeepingNonEmptyAncestor() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/stale/sub/only.jpg", "SHARED")
    _ = try put(r.drive, "Pics/keep/only.jpg", "SHARED")   // keeps 'Pics' non-empty
    _ = try put(r.local, "album/only.jpg", "SHARED")
    try r.cat.upsert(instances: [inst(r.local.id, "album/only.jpg", h)])
    try Manifest.write([mEntry("Pics/stale/sub/only.jpg", h), mEntry("Pics/keep/only.jpg", h)], to: r.drive.manifestURL)
    try r.cat.replaceVaultPresence(vaultID: r.drive.id, entries: [pres(h, "Pics/stale/sub/only.jpg"), pres(h, "Pics/keep/only.jpg")])

    _ = try ReconcileExecutor.applyStaleRemovals([P(h, "Pics/stale/sub/only.jpg")],
            drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: r.drive.absoluteURL(forRelativePath: "Pics/stale/sub").path))  // husk gone
    #expect(!fm.fileExists(atPath: r.drive.absoluteURL(forRelativePath: "Pics/stale").path))       // and its parent
    #expect(fm.fileExists(atPath: r.drive.absoluteURL(forRelativePath: "Pics/keep").path))         // sibling kept
    #expect(fm.fileExists(atPath: r.drive.absoluteURL(forRelativePath: "Pics").path))              // ancestor kept
    #expect(r.onDrive("Pics/keep/only.jpg"))
}

// RELOCATION: a same-hash move on the drive, verified on disk first, updates the manifest.
@Test func relocatesVerifiedFileAndUpdatesManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.drive, "Pics/old/1.jpg", "one")
    try Manifest.write([mEntry("Pics/old/1.jpg", h)], to: r.drive.manifestURL)

    let n = try ReconcileExecutor.applyRelocations(
        [ReconcilePlan.Relocation(hash: h, from: "Pics/old/1.jpg", to: "Pics/new/1.jpg")],
        drive: r.drive, macVaultID: "mac")

    #expect(n == 1)
    #expect(!r.onDrive("Pics/old/1.jpg") && r.onDrive("Pics/new/1.jpg"))
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/new/1.jpg"])
}

// SAFETY: if the source file isn't the content the plan expects, don't move it.
@Test func skipsRelocationOnHashMismatch() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    _ = try put(r.drive, "Pics/old/1.jpg", "actual")
    let wrong = "sha256:" + String(repeating: "9", count: 64)
    try Manifest.write([mEntry("Pics/old/1.jpg", wrong)], to: r.drive.manifestURL)

    let n = try ReconcileExecutor.applyRelocations(
        [ReconcilePlan.Relocation(hash: wrong, from: "Pics/old/1.jpg", to: "Pics/new/1.jpg")],
        drive: r.drive, macVaultID: "mac")

    #expect(n == 0)
    #expect(r.onDrive("Pics/old/1.jpg") && !r.onDrive("Pics/new/1.jpg"))
}

// COPY: bring missing content in from a verified LOCAL source, hash-checked, adding the manifest row.
@Test func copiesFromVerifiedLocalSourceAndAddsManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "album/1.jpg", "payload")
    try r.cat.upsert(instances: [inst(r.local.id, "album/1.jpg", h)])
    try Manifest.write([], to: r.drive.manifestURL)

    let res = try ReconcileExecutor.applyCopies([P(h, "Pics/dest/1.jpg")],
        drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.CopyResult(copied: 1, skipped: 0))
    #expect(r.onDrive("Pics/dest/1.jpg"))
    #expect(try ContentHash.ofFile(at: r.drive.absoluteURL(forRelativePath: "Pics/dest/1.jpg")).stringValue == h)
    #expect(try Manifest.read(from: r.drive.manifestURL).map(\.path) == ["Pics/dest/1.jpg"])
    #expect(r.onLocal("album/1.jpg"))   // source untouched
}

// COPY carries the XMP sidecar (human metadata) alongside the media.
@Test func copyAlsoCopiesSidecar() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "album/1.jpg", "payload")
    let srcSidecar = r.local.sidecarURL(forMediaAt: r.local.absoluteURL(forRelativePath: "album/1.jpg"))
    try FileManager.default.createDirectory(at: srcSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("<xmp/>".utf8).write(to: srcSidecar)
    try r.cat.upsert(instances: [inst(r.local.id, "album/1.jpg", h)])
    try Manifest.write([], to: r.drive.manifestURL)

    _ = try ReconcileExecutor.applyCopies([P(h, "Pics/dest/1.jpg")],
        drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    let destSidecar = r.drive.sidecarURL(forMediaAt: r.drive.absoluteURL(forRelativePath: "Pics/dest/1.jpg"))
    #expect(FileManager.default.fileExists(atPath: destSidecar.path))
}

// COPY skips when no local source has the content (leave it for another drive/source), touching nothing.
@Test func skipsCopyWhenNoLocalSource() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try Manifest.write([], to: r.drive.manifestURL)

    let res = try ReconcileExecutor.applyCopies([P(h, "Pics/dest/1.jpg")],
        drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.CopyResult(copied: 0, skipped: 1))
    #expect(!r.onDrive("Pics/dest/1.jpg"))
    #expect(try Manifest.read(from: r.drive.manifestURL).isEmpty)
}

// COPY skips a destination that's already present (drift), never overwriting.
@Test func skipsCopyWhenAlreadyPresent() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let r = try Rig(t)
    let h = try put(r.local, "album/1.jpg", "payload")
    _ = try put(r.drive, "Pics/dest/1.jpg", "payload")
    try r.cat.upsert(instances: [inst(r.local.id, "album/1.jpg", h)])
    try Manifest.write([mEntry("Pics/dest/1.jpg", h)], to: r.drive.manifestURL)

    let res = try ReconcileExecutor.applyCopies([P(h, "Pics/dest/1.jpg")],
        drive: r.drive, localVault: r.local, catalog: r.cat, macVaultID: "mac")

    #expect(res == ReconcileExecutor.CopyResult(copied: 0, skipped: 1))
}
