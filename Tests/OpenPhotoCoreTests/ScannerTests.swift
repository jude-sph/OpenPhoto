import Testing
import Foundation
@testable import OpenPhotoCore

// Foundation also exports a class called Scanner; disambiguate in this file.
private typealias Scanner = OpenPhotoCore.Scanner

private func fixtureVault(_ t: TestDirs) throws -> (Vault, Catalog) {
    let root = try t.sub("Pictures")
    try makeJPEG(at: root.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: root.appendingPathComponent("rome2022/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:08 10:00:00", lat: nil, lon: nil)
    try makeJPEG(at: root.appendingPathComponent("mac-screenshots/nested/s1.jpg").creatingParent(),
                 dateTimeOriginal: nil, lat: nil, lon: nil)
    try t.file("Pictures/rome2022/notes.txt", Data("ignore me".utf8))
    let vault = try Vault.openOrCreate(at: root, role: .local)
    let cat = try Catalog(at: t.root.appendingPathComponent("catalog.sqlite"))
    try cat.registerVault(id: vault.descriptor.vaultID, role: "local", rootPath: root.path)
    return (vault, cat)
}

extension URL {
    func creatingParent() -> URL {
        try? FileManager.default.createDirectory(
            at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

@Test func initialScanIndexesMediaOnly() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    let result = try await Scanner.scan(vault: vault, catalog: cat)
    #expect(result.hashed == 3)
    #expect(try cat.timelineItems().count == 3)              // .txt and .openphoto skipped
    #expect(try Manifest.read(from: vault.manifestURL).count == 3)
}

@Test func rescanIsFastPathNoop() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try await Scanner.scan(vault: vault, catalog: cat)
    let second = try await Scanner.scan(vault: vault, catalog: cat)
    #expect(second.hashed == 0)                              // size+mtime matched
    #expect(try cat.timelineItems().count == 3)
}

@Test func renameKeepsIdentity() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try await Scanner.scan(vault: vault, catalog: cat)
    let before = try #require(try cat.timelineItems().first { $0.relPath == "rome2022/IMG_1.jpg" })
    try FileManager.default.moveItem(
        at: vault.rootURL.appendingPathComponent("rome2022/IMG_1.jpg"),
        to: vault.rootURL.appendingPathComponent("rome2022/renamed.jpg"))
    _ = try await Scanner.scan(vault: vault, catalog: cat)
    let after = try cat.timelineItems().first { $0.relPath == "rome2022/renamed.jpg" }
    #expect(after?.hash == before.hash)                      // same asset, new path
    #expect(try cat.timelineItems().count == 3)
}

@Test func deletedFileLeavesTimeline() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    _ = try await Scanner.scan(vault: vault, catalog: cat)
    try FileManager.default.removeItem(
        at: vault.rootURL.appendingPathComponent("rome2022/IMG_2.jpg"))
    _ = try await Scanner.scan(vault: vault, catalog: cat)
    #expect(try cat.timelineItems().count == 2)
    #expect(try cat.assetCount() == 3)                       // asset row preserved
}

@Test func reportsProgress() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (vault, cat) = try fixtureVault(t)
    var events: [Scanner.Progress] = []
    _ = try await Scanner.scan(vault: vault, catalog: cat) { events.append($0) }
    #expect(events.contains { $0.stage == .hashing })
    #expect(events.last?.done == events.last?.total)
}
