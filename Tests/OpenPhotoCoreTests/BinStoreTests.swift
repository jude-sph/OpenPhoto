import Testing
import Foundation
@testable import OpenPhotoCore

@Test func deleteMovesToBinPreservingPathAndLogs() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    let media = try t.file("Pictures/rome2022/IMG_1.jpg", Data("img".utf8))
    try t.file("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp", Data("<x/>".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)

    try bin.moveToBin(relPath: "rome2022/IMG_1.jpg",
                      hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)),
                      origin: .user)

    #expect(!FileManager.default.fileExists(atPath: media.path))
    let binned = root.appendingPathComponent(".openphoto/bin/rome2022/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: binned.path))
    // Sidecar travels into the bin beside it (same convention).
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".openphoto/bin/rome2022/.openphoto/IMG_1.jpg.xmp").path))
    let items = try bin.list()
    #expect(items.count == 1 && items[0].path == "rome2022/IMG_1.jpg" && items[0].origin == .user)
}

@Test func restorePutsFileBack() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("Pictures")
    try t.file("Pictures/a/b.jpg", Data("x".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let bin = BinStore(vault: vault)
    let h = ContentHash(stringValue: "sha256:" + String(repeating: "b", count: 64))
    try bin.moveToBin(relPath: "a/b.jpg", hash: h, origin: .user)
    try bin.restore(relPath: "a/b.jpg")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b.jpg").path))
    #expect(try bin.list().isEmpty)
}
