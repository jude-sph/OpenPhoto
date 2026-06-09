import Testing
import Foundation
@testable import OpenPhotoCore

/// A drive vault with two media files already in its manifest.
private func driveWithManifest(_ t: TestDirs) throws -> Vault {
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    try makeJPEG(at: root.appendingPathComponent("Pictures/a.jpg").creatingParent(),
                 dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    try makeJPEG(at: root.appendingPathComponent("Pictures/b.jpg").creatingParent(),
                 dateTimeOriginal: "2022:01:02 00:00:00", lat: nil, lon: nil)
    // Build a manifest matching the two files.
    let entries = try ["Pictures/a.jpg", "Pictures/b.jpg"].map { rel -> ManifestEntry in
        let url = root.appendingPathComponent(rel)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return ManifestEntry(hash: try ContentHash.ofFile(at: url),
                             path: rel, size: (a[.size] as? Int64) ?? 0,
                             mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    return drive
}

@Test func scanCleanDriveHasNoFindings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWithManifest(t)
    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.isClean)
    #expect(report.presentHashes.count == 2)
}

@Test func scanDetectsMissingUnknownAndChanged() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWithManifest(t)
    let root = drive.rootURL
    // missing: delete b.jpg
    try FileManager.default.removeItem(at: root.appendingPathComponent("Pictures/b.jpg"))
    // unknown: drop a media file not in the manifest
    try makeJPEG(at: root.appendingPathComponent("Pictures/c.jpg"),
                 dateTimeOriginal: "2022:01:03 00:00:00", lat: nil, lon: nil)
    // changed: append bytes to a.jpg so its size differs from the manifest
    let a = root.appendingPathComponent("Pictures/a.jpg")
    let fh = try FileHandle(forWritingTo: a); try fh.seekToEnd()
    try fh.write(contentsOf: Data([0,1,2,3])); try fh.close()

    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.missing.map(\.relPath) == ["Pictures/b.jpg"])
    #expect(report.unknown.map(\.relPath) == ["Pictures/c.jpg"])
    #expect(report.changed.map(\.relPath) == ["Pictures/a.jpg"])
    #expect(report.presentHashes.isEmpty) // a changed, b missing → neither "present"
    #expect(!report.isClean)
}
