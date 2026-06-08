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
