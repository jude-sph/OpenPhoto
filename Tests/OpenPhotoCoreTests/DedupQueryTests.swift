import Testing
import Foundation
@testable import OpenPhotoCore

private func photo(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                caption: nil, tagsJSON: "[]")
}
private func inst(_ h: String, _ rel: String) -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: "v1", relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 10, mtimeMs: 1)
}
private let DA = "sha256:" + String(repeating: "a", count: 64)
private let DB = "sha256:" + String(repeating: "b", count: 64)

private func seeded() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(DA), photo(DB)])
    try cat.replaceInstances(inVault: "v1", with: [
        inst(DA, "f1/a.jpg"), inst(DA, "f2/a.jpg"),       // same content, DIFFERENT folders
        inst(DB, "f1/b.jpg"), inst(DB, "f1/b copy.jpg"),  // same content, SAME folder
    ])
    return (t, cat)
}

@Test func timelineDedupesByContentButFoldersDoNot() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    // Timeline dedupes by content → one row per hash.
    let timeline = try cat.timelineItems()
    #expect(timeline.count == 2)
    #expect(Set(timeline.map(\.hash)) == [DA, DB])
    // Folders are per-instance → A appears in BOTH of its folders.
    #expect(try cat.items(inDir: "f1").contains { $0.hash == DA })
    #expect(try cat.items(inDir: "f2").contains { $0.hash == DA })
    #expect(try cat.items(inDir: "f1").count == 3)   // a.jpg + b.jpg + b copy.jpg
}

@Test func duplicateGroupsRespectScope() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let within = try cat.duplicateInstanceGroups(scope: .withinFolder)
    #expect(within.count == 1)   // only B (its two copies are in the same folder)
    #expect(Set(within[0]) == ["v1|f1/b.jpg", "v1|f1/b copy.jpg"])
    let anywhere = try cat.duplicateInstanceGroups(scope: .anywhere)
    #expect(anywhere.count == 2) // A (cross-folder) and B
}
