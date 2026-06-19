import Testing
import Foundation
@testable import OpenPhotoCore

@Test func schemaIsV13() { #expect(Catalog.schemaVersion == 13) }

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
    let merged = try lib.reconcileFinderTags(forHash: h, proposedTags: ["a", "b", "c"], favorite: false)
    #expect(Set(merged.tags) == ["b", "c"])
    #expect(merged.favorite == false)
    #expect(Set(FinderTags.read(media)) == ["b", "c"])
    #expect(Set(try lib.catalog.finderTagBaseline(forHash: h)) == ["b", "c"])
}

@Test func reconcileFinderTagsDriveOnlyReturnsProposedAndWritesNothing() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    let h = "sha256:" + String(repeating: "z", count: 64)
    let r = try lib.reconcileFinderTags(forHash: h, proposedTags: ["x"], favorite: false)
    #expect(r.tags == ["x"] && r.favorite == false)
    #expect(try lib.catalog.finderTagBaseline(forHash: h) == [])
}

@Test func reconcileFinderTagsSyncsFavouriteAndReservesTag() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("pics")
    let media = pics.appendingPathComponent("a/IMG.jpg").creatingParent()
    try makeJPEG(at: media, dateTimeOriginal: nil, lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("app"))
    try await lib.scanAll()
    let h = try lib.catalog.timelineItems().first { $0.relPath == "a/IMG.jpg" }!.hash

    // App favourite, no Finder tag yet, fresh baseline → ADD the reserved tag, keep favourite (never cleared).
    let r1 = try lib.reconcileFinderTags(forHash: h, proposedTags: ["x"], favorite: true)
    #expect(r1.favorite == true)
    #expect(r1.tags == ["x"])                                      // reserved stripped from regular tags
    #expect(Set(FinderTags.read(media)) == ["Favourite", "x"])     // reserved written to Finder

    // Finder removes the Favourite tag → favourite clears on the next reconcile (removal propagates).
    try FinderTags.write(["x"], to: media)
    let r2 = try lib.reconcileFinderTags(forHash: h, proposedTags: ["x"], favorite: true)
    #expect(r2.favorite == false)

    // Typing "Favourite" as a regular tag is reserved — never persisted as a tag.
    let r3 = try lib.reconcileFinderTags(forHash: h, proposedTags: ["Favourite", "y"], favorite: false)
    #expect(!r3.tags.contains("Favourite"))
}
