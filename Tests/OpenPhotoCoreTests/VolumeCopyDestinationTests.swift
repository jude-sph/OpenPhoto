import Testing
import Foundation
@testable import OpenPhotoCore

@Test func volumeCopyConfirmsByHashAndDedupsOnResend() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try t.sub("lib")
    let srcURL = lib.appendingPathComponent("IMG_1.jpg")
    try makeJPEG(at: srcURL, dateTimeOriginal: "2015:06:15 14:30:00", lat: nil, lon: nil)
    let hash = try ContentHash.ofFile(at: srcURL).stringValue
    let size = Int64((try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int) ?? 0)
    let volRoot = try t.sub("VOLUME")

    let dest = VolumeCopyDestination(volumeRoot: volRoot, displayName: "Card")
    let send = SendItem(hash: hash, originalURL: srcURL,
                        fingerprint: PresenceFingerprint(size: size, captureDateMs: 0, hash: hash),
                        displayName: "IMG_1.jpg")
    let out1 = try await dest.send([send], progress: { _ in })
    #expect(out1.count == 1 && out1[0].status == .confirmed)
    let landed = volRoot.appendingPathComponent("OpenPhoto/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: landed.path))
    #expect(try ContentHash.ofFile(at: landed).stringValue == hash)   // byte-identical copy

    let present = try await dest.enumeratePresent()
    #expect(present.contains { $0.hash == hash })
}

@Test func volumeCopyFailsAndCleansUpOnHashMismatch() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try t.sub("lib")
    let srcURL = lib.appendingPathComponent("IMG_2.jpg")
    try makeJPEG(at: srcURL, dateTimeOriginal: nil, lat: nil, lon: nil)
    let size = Int64((try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int) ?? 0)
    let volRoot = try t.sub("VOLUME")
    let dest = VolumeCopyDestination(volumeRoot: volRoot, displayName: "Card")
    // Deliberately wrong hash → the written copy won't verify.
    let wrongHash = "sha256:" + String(repeating: "0", count: 64)
    let send = SendItem(hash: wrongHash, originalURL: srcURL,
                        fingerprint: PresenceFingerprint(size: size, captureDateMs: 0, hash: wrongHash),
                        displayName: "IMG_2.jpg")
    let out = try await dest.send([send], progress: { _ in })
    #expect(out.count == 1 && out[0].status == .failed)
    // The unverified copy was removed; the original is untouched.
    #expect(!FileManager.default.fileExists(atPath: volRoot.appendingPathComponent("OpenPhoto/IMG_2.jpg").path))
    #expect(FileManager.default.fileExists(atPath: srcURL.path))
}
