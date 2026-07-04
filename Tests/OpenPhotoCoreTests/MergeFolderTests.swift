import Testing
import Foundation
@testable import OpenPhotoCore

/// Library with scanned JPEGs. Files that share a `date` share bytes → share a content hash (so the
/// same photo can appear in two folders, the way the merge needs to dedup).
private func mergeLibrary(_ t: TestDirs, _ files: [(rel: String, date: String)]) async throws -> LibraryService {
    let root = try t.sub("vault")
    for f in files {
        try makeJPEG(at: root.appendingPathComponent(f.rel).creatingParent(),
                     dateTimeOriginal: "2022:10:07 14:23:\(f.date)", lat: nil, lon: nil)
    }
    let lib = try LibraryService(vaultRoots: [root], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    return lib
}

// The core set-union plan: photos in `src` that are NOT already in `dest` move in (preserving their
// sub-path); photos that ARE already in `dest` are exact duplicates → binned. Nothing in `dest` moves.
@Test func mergeFolderPlanMovesUniquesPreservesSubpathAndBinsExactDuplicates() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await mergeLibrary(t, [
        ("a/uniqueA.jpg", "01"),          // only in a  → move to b
        ("a/shared.jpg", "02"),           // also in b  → bin (dup)
        ("a/sub/deep.jpg", "04"),         // only in a, nested → move to b/sub
        ("b/shared.jpg", "02"),           // same bytes as a/shared → same hash
        ("b/uniqueB.jpg", "03"),          // only in b  → untouched
    ])
    // sanity: a/shared and b/shared are genuinely the same content
    let aShared = try #require(try lib.items(inDir: "a").first { $0.relPath == "a/shared.jpg" })
    let bShared = try #require(try lib.items(inDir: "b").first { $0.relPath == "b/shared.jpg" })
    #expect(aShared.hash == bShared.hash)

    let plan = try lib.mergeFolderPlan(src: "a", into: "b")

    // uniqueA → b, deep → b/sub (subpath preserved). shared → bin. uniqueB untouched.
    let moves = Dictionary(uniqueKeysWithValues: plan.moves.map {
        (($0.instanceID as NSString).lastPathComponent, $0.intoDir) })
    #expect(moves == ["uniqueA.jpg": "b", "deep.jpg": "b/sub"])
    #expect(plan.binInstanceIDs.count == 1 && plan.binInstanceIDs[0].hasSuffix("|a/shared.jpg"))
}

// Two src photos with the SAME content: one moves, the other is a dup within the batch → binned
// (the merged folder keeps exactly one copy of each distinct photo).
@Test func mergeFolderPlanDedupsWithinSourceToo() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await mergeLibrary(t, [
        ("a/one.jpg", "07"), ("a/one-copy.jpg", "07"),   // identical content, both in a
    ])
    let plan = try lib.mergeFolderPlan(src: "a", into: "b")   // b doesn't exist yet
    #expect(plan.moves.count == 1)                            // one copy moves into b
    #expect(plan.binInstanceIDs.count == 1)                   // the intra-src duplicate is binned
}
