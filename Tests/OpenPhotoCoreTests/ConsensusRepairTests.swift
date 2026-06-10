import Testing
import Foundation
@testable import OpenPhotoCore

private func seedCorruptDrive(_ t: TestDirs) throws -> (Vault, String, String, URL) {
    // A drive whose manifest records the GOOD hash for rel, but whose on-disk bytes are ROTTEN.
    // Returns (drive, rel, goodHash, goodSourceURL).
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let rel = "Pictures/rome/IMG_1.jpg"
    let dest = drive.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let source = t.root.appendingPathComponent("good.jpg")
    try Data("the real photo bytes".utf8).write(to: source)
    let goodHash = try ContentHash.ofFile(at: source).stringValue
    try Data("ROTTEN".utf8).write(to: dest)   // on-disk bytes don't match the manifest
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: goodHash), path: rel,
        size: 20, mtime: "2022-10-07T14:23:01.000Z")], to: drive.manifestURL)
    return (drive, rel, goodHash, source)
}

@Test func repairCorruptReplacesFromGoodCopyAndBinsTheRot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (drive, rel, goodHash, source) = try seedCorruptDrive(t)

    try DriftReconciler().repairCorrupt(relPath: rel, expectedHash: goodHash, from: source, on: drive)

    // The slot now holds the verified-good bytes.
    #expect(try ContentHash.ofFile(at: drive.absoluteURL(forRelativePath: rel)).stringValue == goodHash)
    // The rotten original is quarantined in the drive bin with origin .repaired.
    let bin = BinStore(vault: drive)
    #expect(try bin.list().contains { $0.path == rel && $0.origin == .repaired })
    #expect(FileManager.default.fileExists(atPath: bin.binnedFileURL(relPath: rel).path))
    // The manifest still records the good hash (size/mtime re-recorded to the placed file).
    let entry = try #require(try Manifest.read(from: drive.manifestURL).first { $0.path == rel })
    #expect(entry.hash.stringValue == goodHash)
}

@Test func repairCorruptAbortsOnRottenSourceLeavingSlotIntact() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (drive, rel, goodHash, _) = try seedCorruptDrive(t)
    let dest = drive.absoluteURL(forRelativePath: rel)
    // A "source" whose bytes do NOT hash to goodHash.
    let badSource = t.root.appendingPathComponent("bad.jpg")
    try Data("also the wrong bytes".utf8).write(to: badSource)

    #expect(throws: (any Error).self) {
        try DriftReconciler().repairCorrupt(relPath: rel, expectedHash: goodHash, from: badSource, on: drive)
    }
    // Slot untouched (still the rotten on-disk bytes) and NOTHING binned.
    #expect(try Data(contentsOf: dest) == Data("ROTTEN".utf8))
    #expect(try BinStore(vault: drive).list().isEmpty)
}

@Test func binOriginRepairedRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("d"), role: .canonical)
    let rel = "Pictures/a.jpg"
    let f = drive.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: f)
    try BinStore(vault: drive).moveToBin(relPath: rel,
        hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)), origin: .repaired)
    #expect(try BinStore(vault: drive).list().first?.origin == .repaired)
}
