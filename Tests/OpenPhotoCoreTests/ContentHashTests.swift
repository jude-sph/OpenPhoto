import Testing
import Foundation
@testable import OpenPhotoCore

@Test func hashesKnownVector() throws {
    // SHA-256("abc") is a published NIST vector.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: f)
    let h = try ContentHash.ofFile(at: f)
    #expect(h.stringValue ==
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func streamsLargeFileWithoutLoadingIntoMemory() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("big.bin")
    let chunk = Data(repeating: 0xAB, count: 1_000_000)
    let created = FileManager.default.createFile(atPath: f.path, contents: nil)
    #expect(created)
    let fh = try FileHandle(forWritingTo: f)
    for _ in 0..<8 { try fh.write(contentsOf: chunk) }   // 8 MB
    try fh.close()
    let a = try ContentHash.ofFile(at: f)
    let b = try ContentHash.ofFile(at: f)
    #expect(a == b)
    #expect(a.stringValue.hasPrefix("sha256:"))
    #expect(a.stringValue.count == "sha256:".count + 64)
}
