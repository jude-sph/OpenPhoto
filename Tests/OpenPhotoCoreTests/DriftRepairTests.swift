import Testing
import Foundation
@testable import OpenPhotoCore

private func driveWith(_ t: TestDirs, files: [String]) throws -> Vault {
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    var entries: [ManifestEntry] = []
    for rel in files {
        try makeJPEG(at: root.appendingPathComponent(rel).creatingParent(),
                     dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
        let url = root.appendingPathComponent(rel)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        entries.append(ManifestEntry(hash: try ContentHash.ofFile(at: url), path: rel,
            size: (a[.size] as? Int64) ?? 0,
            mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date())))
    }
    try Manifest.write(entries, to: drive.manifestURL)
    return drive
}

@Test func adoptAddsUnknownFileToManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    // a stray file on disk, not in the manifest
    try makeJPEG(at: drive.rootURL.appendingPathComponent("Pictures/stray.jpg"),
                 dateTimeOriginal: "2022:02:02 00:00:00", lat: nil, lon: nil)
    let hash = try DriftReconciler().adopt(relPath: "Pictures/stray.jpg", on: drive)
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(entries.contains { $0.path == "Pictures/stray.jpg" && $0.hash.stringValue == hash })
}

@Test func restoreCopiesGoodBytesIntoEmptySlot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    // the good source (e.g. on the Mac) and the recorded hash
    let recorded = try Manifest.read(from: drive.manifestURL).first { $0.path == "Pictures/a.jpg" }!
    let source = try t.file("mac/a.jpg", try Data(contentsOf:
        drive.rootURL.appendingPathComponent("Pictures/a.jpg")))
    // simulate "missing": delete it from the drive
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/a.jpg"))

    try DriftReconciler().restore(relPath: "Pictures/a.jpg", expectedHash: recorded.hash.stringValue,
                                  from: source, on: drive)
    let dest = drive.rootURL.appendingPathComponent("Pictures/a.jpg")
    #expect(try ContentHash.ofFile(at: dest).stringValue == recorded.hash.stringValue)
    #expect(try Manifest.read(from: drive.manifestURL).contains { $0.path == "Pictures/a.jpg" })
}

@Test func restoreThrowsWhenSourceBytesDontMatch() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg"])
    let recorded = try Manifest.read(from: drive.manifestURL).first!
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/a.jpg"))
    let badSource = try t.file("mac/bad.jpg", Data("not the right bytes".utf8))
    #expect(throws: DriftError.self) {
        try DriftReconciler().restore(relPath: "Pictures/a.jpg",
            expectedHash: recorded.hash.stringValue, from: badSource, on: drive)
    }
    #expect(!FileManager.default.fileExists(atPath:
        drive.rootURL.appendingPathComponent("Pictures/a.jpg").path))
}

@Test func acknowledgeGoneDropsManifestLine() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try driveWith(t, files: ["Pictures/a.jpg", "Pictures/b.jpg"])
    try FileManager.default.removeItem(at: drive.rootURL.appendingPathComponent("Pictures/b.jpg"))
    try DriftReconciler().acknowledgeGone(relPath: "Pictures/b.jpg", on: drive)
    #expect(try Manifest.read(from: drive.manifestURL).map(\.path) == ["Pictures/a.jpg"])
}
