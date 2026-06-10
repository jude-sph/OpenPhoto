import Testing
import Foundation
@testable import OpenPhotoCore

@Test func verifiedCopySucceedsAndVerifies() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("hello".utf8))
    let hash = try ContentHash.ofFile(at: src).stringValue
    let dest = t.root.appendingPathComponent("drive/x/a.bin")
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: hash) == true)
    #expect(try Data(contentsOf: dest) == Data("hello".utf8))
}

@Test func verifiedCopyFailsOnHashMismatchAndLeavesNoFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("hello".utf8))
    let dest = t.root.appendingPathComponent("drive/x/a.bin")
    let wrong = "sha256:" + String(repeating: "f", count: 64)
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: wrong) == false)
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    // no orphan temp files in the dest dir
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
    #expect(siblings.allSatisfy { !$0.hasPrefix(".tmp-") })
}

@Test func verifiedCopyNeverOverwritesExistingDest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let src = try t.file("src/a.bin", Data("new".utf8))
    let hash = try ContentHash.ofFile(at: src).stringValue
    let dest = try t.file("drive/x/a.bin", Data("original".utf8))
    #expect(VerifiedCopy.copy(from: src, to: dest, expectedHash: hash) == false)
    #expect(try Data(contentsOf: dest) == Data("original".utf8)) // untouched
}
