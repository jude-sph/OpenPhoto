import Testing
import Foundation
@testable import OpenPhotoCore

@Test func verifyDetectsBitRotWithUnchangedSizeAndMtime() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    let url = root.appendingPathComponent("Pictures/a.jpg")
    try makeJPEG(at: url.creatingParent(), dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    let a0 = try FileManager.default.attributesOfItem(atPath: url.path)
    let savedMtime = (a0[.modificationDate] as? Date) ?? Date()
    let entry = ManifestEntry(hash: try ContentHash.ofFile(at: url), path: "Pictures/a.jpg",
        size: (a0[.size] as? Int64) ?? 0, mtime: ISO8601Millis.string(from: savedMtime))
    try Manifest.write([entry], to: drive.manifestURL)

    // Flip one byte in place WITHOUT changing length, then restore the mtime.
    let fh = FileHandle(forUpdatingAtPath: url.path)!
    try fh.seek(toOffset: 0); let first = try fh.read(upToCount: 1) ?? Data([0])
    try fh.seek(toOffset: 0); try fh.write(contentsOf: Data([first[0] ^ 0xFF])); try fh.close()
    try FileManager.default.setAttributes([.modificationDate: savedMtime], ofItemAtPath: url.path)

    // Fast scan can't see it (size+mtime unchanged); verify can.
    #expect(try DriftReconciler().scan(drive: drive).corrupt.isEmpty)
    let report = try DriftReconciler().verify(drive: drive)
    #expect(report.corrupt.map(\.relPath) == ["Pictures/a.jpg"])
    #expect(report.presentHashes.isEmpty)
    #expect(report.verified == true)
}

@Test func verifyCleanDriveListsAllPresent() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let drive = try Vault.openOrCreate(at: root, role: .canonical)
    let url = root.appendingPathComponent("Pictures/a.jpg")
    try makeJPEG(at: url.creatingParent(), dateTimeOriginal: "2022:01:01 00:00:00", lat: nil, lon: nil)
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    try Manifest.write([ManifestEntry(hash: try ContentHash.ofFile(at: url), path: "Pictures/a.jpg",
        size: (a[.size] as? Int64) ?? 0,
        mtime: ISO8601Millis.string(from: (a[.modificationDate] as? Date) ?? Date()))],
        to: drive.manifestURL)
    let report = try DriftReconciler().verify(drive: drive)
    #expect(report.isClean)
    #expect(report.presentHashes.count == 1)
}
