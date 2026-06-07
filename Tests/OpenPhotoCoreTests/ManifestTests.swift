import Testing
import Foundation
@testable import OpenPhotoCore

@Test func roundTripsEntries() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    let entries = [
        ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)),
                      path: "rome2022/IMG_1.heic", size: 123,
                      mtime: "2022-10-07T14:23:01.512Z"),
        ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "b", count: 64)),
                      path: "canada23/IMG_2.mov", size: 456_789,
                      mtime: "2023-02-01T09:00:00.000Z"),
    ]
    try Manifest.write(entries, to: url)
    let read = try Manifest.read(from: url)
    #expect(read == entries.sorted(by: { $0.path < $1.path }))
    #expect(read.first?.path == "canada23/IMG_2.mov")   // sorted, not insertion, order
}

@Test func emptyOrMissingManifestReadsAsEmpty() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    #expect(try Manifest.read(from: url) == [])
}

@Test func linesAreStableSingleObjects() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    let e = ManifestEntry(hash: ContentHash(stringValue: "sha256:" + String(repeating: "c", count: 64)),
                          path: "a/b.jpg", size: 1, mtime: "2026-01-01T00:00:00.000Z")
    try Manifest.write([e], to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("{") && lines[0].hasSuffix("}"))
    #expect(text.hasSuffix("\n"))
}

@Test func unreadableManifestThrowsRatherThanReadingEmpty() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("manifest.jsonl")
    try Manifest.write([ManifestEntry(
        hash: ContentHash(stringValue: "sha256:" + String(repeating: "d", count: 64)),
        path: "x.jpg", size: 1, mtime: "2026-01-01T00:00:00.000Z")], to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    #expect(throws: (any Error).self) { try Manifest.read(from: url) }
}
