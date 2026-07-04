import Testing
import Foundation
@testable import OpenPhotoCore

private func seed(_ vault: Vault, _ rel: String, _ bytes: String) throws -> ContentHash {
    let url = vault.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url)
    return try ContentHash.ofFile(at: url)
}

/// Manifest entry built from the file's ACTUAL size+mtime (the keys the drift walk reads), so a drift
/// scan afterwards is deterministic.
private func realEntry(_ vault: Vault, _ rel: String, _ h: ContentHash) throws -> ManifestEntry {
    let v = try vault.absoluteURL(forRelativePath: rel)
        .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return ManifestEntry(hash: h, path: rel, size: Int64(v.fileSize ?? 0),
                         mtime: ISO8601Millis.string(from: v.contentModificationDate ?? Date()))
}

// adoptMany records EVERY unknown file in a SINGLE manifest rewrite (not one per file), read-only on
// the media, leaving the drive drift-clean and pre-existing entries intact.
@Test func adoptManyAddsAllInOneWriteReadOnlyAndDriftClean() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let drive = try Vault.openOrCreate(at: root, role: .canonical)

    // One already-known file (in the manifest) + two "unknown" files present on disk but not recorded.
    let hKnown = try seed(drive, "known/a.jpg", "aaa")
    try Manifest.write([try realEntry(drive, "known/a.jpg", hKnown)], to: drive.manifestURL)
    _ = try seed(drive, "new/b.jpg", "bbbb")
    _ = try seed(drive, "new/c.jpg", "ccccc")

    let adopted = try DriftReconciler().adoptMany(relPaths: ["new/b.jpg", "new/c.jpg"], on: drive)

    #expect(Set(adopted.keys) == ["new/b.jpg", "new/c.jpg"])
    // All three now in the manifest — the pre-existing entry untouched, the two new ones added.
    #expect(Set(try Manifest.read(from: drive.manifestURL).map(\.path))
                == ["known/a.jpg", "new/b.jpg", "new/c.jpg"])
    // The media files are all still on disk (adopt never moves/deletes them).
    for rel in ["known/a.jpg", "new/b.jpg", "new/c.jpg"] {
        #expect(FileManager.default.fileExists(atPath: drive.absoluteURL(forRelativePath: rel).path))
    }
    // Drift-clean: nothing reads as unknown/missing/changed after adoption.
    let report = try DriftReconciler().scan(drive: drive)
    #expect(report.unknown.isEmpty && report.missing.isEmpty && report.changed.isEmpty)
    #expect(report.presentHashes.count == 3)
}

// A file that vanished before adoption is simply skipped — the batch continues.
@Test func adoptManySkipsMissingFiles() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = t.root.appendingPathComponent("V")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    try Manifest.write([], to: drive.manifestURL)
    _ = try seed(drive, "here.jpg", "x")

    let adopted = try DriftReconciler().adoptMany(relPaths: ["here.jpg", "gone.jpg"], on: drive)

    #expect(Array(adopted.keys) == ["here.jpg"])
    #expect(try Manifest.read(from: drive.manifestURL).map(\.path) == ["here.jpg"])
}
