import Testing
import Foundation
@testable import OpenPhotoCore

/// Library over one temp vault with a single scanned JPEG.
private func oneJpegLibrary(_ t: TestDirs) async throws -> LibraryService {
    let root = try t.sub("vault")
    try makeJPEG(at: root.appendingPathComponent("a/x.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:00", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [root], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    return lib
}

private func tags(of item: TimelineItem) -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
}

// appendTag adds a keyword tag, MERGING with existing tags (never replacing), and is idempotent.
@Test func appendTagMergesWithExistingTagsAndIsIdempotent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await oneJpegLibrary(t)
    var item = try #require(try lib.items(inDir: "a").first)
    // Pre-existing hand-set tag we must not clobber.
    try lib.updateMetadata(for: item, rating: 3, favorite: true, caption: "hi", tags: ["Holiday"])
    item = try #require(try lib.items(inDir: "a").first)

    try lib.appendTag("From Apple Photos", toItems: [item])

    let after = try #require(try lib.items(inDir: "a").first)
    #expect(Set(tags(of: after)) == ["Holiday", "From Apple Photos"])   // merged, not replaced
    #expect(after.favorite == true && after.rating == 3 && after.caption == "hi")   // other metadata intact

    // Idempotent: a second append does not duplicate the tag.
    try lib.appendTag("From Apple Photos", toItems: [after])
    #expect(tags(of: try #require(try lib.items(inDir: "a").first))
                .filter { $0 == "From Apple Photos" }.count == 1)
}

// The tag is durable: written to the XMP sidecar, so a full rescan (rebuilds the catalog from disk)
// still shows it.
@Test func appendTagSurvivesRescan() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await oneJpegLibrary(t)
    let item = try #require(try lib.items(inDir: "a").first)

    try lib.appendTag("From Apple Photos", toItems: [item])
    try await lib.rescan(vaultID: lib.vaults[0].descriptor.vaultID)

    #expect(tags(of: try #require(try lib.items(inDir: "a").first)) == ["From Apple Photos"])
}
