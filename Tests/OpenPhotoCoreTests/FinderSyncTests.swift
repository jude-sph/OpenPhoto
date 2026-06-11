import Testing
import Foundation
@testable import OpenPhotoCore

@Test func schemaIsV11() { #expect(Catalog.schemaVersion == 11) }

@Test func finderTagBaselineRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    #expect(try cat.finderTagBaseline(forHash: "h") == [])
    try cat.setFinderTagBaseline(hash: "h", tags: ["a", "b"])
    #expect(Set(try cat.finderTagBaseline(forHash: "h")) == ["a", "b"])
    try cat.setFinderTagBaseline(hash: "h", tags: ["a"])      // replace
    #expect(try cat.finderTagBaseline(forHash: "h") == ["a"])
}

@Test func reconcileFinderTagsMergesWritesAndBaselines() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let media = pics.appendingPathComponent("rome/IMG.jpg").creatingParent()
    try makeJPEG(at: media, dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    try await lib.scanAll()
    let h = try lib.catalog.timelineItems().first { $0.relPath == "rome/IMG.jpg" }!.hash
    try lib.catalog.setFinderTagBaseline(hash: h, tags: ["a", "b"])
    try FinderTags.write(["b"], to: media)
    let merged = try lib.reconcileFinderTags(forHash: h, proposedTags: ["a", "b", "c"])
    #expect(Set(merged) == ["b", "c"])
    #expect(Set(FinderTags.read(media)) == ["b", "c"])
    #expect(Set(try lib.catalog.finderTagBaseline(forHash: h)) == ["b", "c"])
}

@Test func reconcileFinderTagsDriveOnlyReturnsProposedAndWritesNothing() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    let h = "sha256:" + String(repeating: "z", count: 64)
    #expect(try lib.reconcileFinderTags(forHash: h, proposedTags: ["x"]) == ["x"])
    #expect(try lib.catalog.finderTagBaseline(forHash: h) == [])
}
