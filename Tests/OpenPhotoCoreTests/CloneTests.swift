import Testing
import Foundation
@testable import OpenPhotoCore

/// A canonical drive seeded with one file already in drive layout (`Pictures/rome/IMG_1.jpg`)
/// plus its manifest entry. Returns (lib, canonical, backup, drivePath, hash, bytes).
private func cloneFixture(_ t: TestDirs) throws
    -> (LibraryService, Vault, Vault, String, String, Data) {
    let lib = try LibraryService(vaultRoots: [try t.sub("Pictures")], appSupportDir: try t.sub("as"))
    let canonical = try Vault.openOrCreate(at: try t.sub("canon"), role: .canonical)
    let backup = try Vault.openOrCreate(at: try t.sub("backup"), role: .backup)
    let drivePath = "Pictures/rome/IMG_1.jpg"
    let bytes = Data("photo-bytes-one".utf8)
    let f = canonical.rootURL.appendingPathComponent(drivePath)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: f)
    let hash = try ContentHash.ofFile(at: f).stringValue
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath,
                                      size: Int64(bytes.count), mtime: "2022-10-07T14:23:01.000Z")],
                       to: canonical.manifestURL)
    return (lib, canonical, backup, drivePath, hash, bytes)
}

@Test func planCloneMirrorsIdentityMappedAndCopies() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, drivePath, _, bytes) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)

    let plan = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan.copies.count == 1)
    #expect(plan.copies[0].destRelPath == drivePath)   // identity — NOT "canon/Pictures/..."

    let result = await engine.apply(plan, destinationVault: backup,
                                    volume: FileSystemVolume(rootURL: backup.rootURL),
                                    event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    #expect(result.copied == 1)
    let copied = backup.rootURL.appendingPathComponent(drivePath)
    #expect(FileManager.default.fileExists(atPath: copied.path))
    #expect(try Data(contentsOf: copied) == bytes)
    #expect(Set(try Manifest.read(from: backup.manifestURL).map(\.path)) == [drivePath])
}

@Test func planCloneIsAdditiveDiffAndNeverOverwrites() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, drivePath, hash, _) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)
    // First clone copies the one file.
    _ = await engine.apply(try engine.planClone(source: canonical, destinationVault: backup),
                           destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    // Same hash already on backup → re-plan is empty (skip).
    #expect(try engine.planClone(source: canonical, destinationVault: backup).copies.isEmpty)

    // Add a SECOND file to canonical → only it is planned (diff-driven).
    let p2 = "Pictures/rome/IMG_2.jpg"
    let f2 = canonical.rootURL.appendingPathComponent(p2)
    try Data("photo-bytes-two".utf8).write(to: f2)
    let h2 = try ContentHash.ofFile(at: f2).stringValue
    try Manifest.write([
        ManifestEntry(hash: ContentHash(stringValue: hash), path: drivePath, size: 15, mtime: "2022-10-07T14:23:01.000Z"),
        ManifestEntry(hash: ContentHash(stringValue: h2), path: p2, size: 15, mtime: "2022-10-07T14:24:01.000Z"),
    ], to: canonical.manifestURL)
    let plan2 = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan2.copies.map(\.destRelPath) == [p2])

    // A backup file at the same path but DIFFERENT bytes → conflict, never overwritten.
    let conflicting = backup.rootURL.appendingPathComponent(p2)
    try Data("different-bytes".utf8).write(to: conflicting)
    let plan3 = try engine.planClone(source: canonical, destinationVault: backup)
    #expect(plan3.copies.isEmpty)
    #expect(plan3.conflicts.map(\.destRelPath) == [p2])
    _ = await engine.apply(plan3, destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)
    #expect(try Data(contentsOf: conflicting) == Data("different-bytes".utf8))   // untouched
}

@Test func cloneLogsCloneEventOnDriveAndNotOnMac() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, canonical, backup, _, _, _) = try cloneFixture(t)
    let engine = SyncEngine(library: lib)
    _ = await engine.apply(try engine.planClone(source: canonical, destinationVault: backup),
                           destinationVault: backup, volume: FileSystemVolume(rootURL: backup.rootURL),
                           event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)

    let driveLog = try String(contentsOf: backup.syncLogURL, encoding: .utf8)
    #expect(driveLog.contains("\"clone\""))
    #expect(driveLog.contains(canonical.descriptor.vaultID))
    // No mac-side "clone" line (clone is drive→drive).
    let macURL = lib.vaults[0].syncLogURL
    let macHasClone = FileManager.default.fileExists(atPath: macURL.path)
        && ((try? String(contentsOf: macURL, encoding: .utf8))?.contains("clone") ?? false)
    #expect(!macHasClone)
}
