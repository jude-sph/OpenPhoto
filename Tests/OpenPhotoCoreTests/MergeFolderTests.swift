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

// Merging a folder INTO ITS PARENT: the parent's recursive listing contains the source's own photos,
// which used to make every one an "exact duplicate" of itself → the whole folder was binned.
@Test func mergeIntoParentMovesPhotosInsteadOfBinningThem() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await mergeLibrary(t, [
        ("Trips/Japan/a.jpg", "01"),
        ("Trips/Japan/day2/b.jpg", "02"),
        ("Trips/Japan/dupe.jpg", "03"),   // same bytes as Trips/other.jpg → a REAL duplicate
        ("Trips/other.jpg", "03"),
    ])
    let plan = try lib.mergeFolderPlan(src: "Trips/Japan", into: "Trips")
    let moves = Dictionary(uniqueKeysWithValues: plan.moves.map {
        (($0.instanceID as NSString).lastPathComponent, $0.intoDir) })
    #expect(moves == ["a.jpg": "Trips", "b.jpg": "Trips/day2"])
    #expect(plan.binInstanceIDs.count == 1 && plan.binInstanceIDs[0].hasSuffix("|Trips/Japan/dupe.jpg"))
}

// A rescan that finds nothing new must not rewrite the manifest (two full disk flushes) nor touch
// instance rows; a real change must still land.
@Test func unchangedRescanWritesNothingAndChangesStillLand() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try await mergeLibrary(t, [("a/one.jpg", "01"), ("a/two.jpg", "02"), ("b/three.jpg", "03")])
    let vault = try #require(lib.vaults.first)
    func inode() throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: vault.manifestURL.path)[.systemFileNumber] as? UInt64) ?? 0
    }
    let before = try inode()
    let rowsBefore = try lib.catalog.instanceHashPaths(vaultID: vault.id).map(\.relPath).sorted()

    try await lib.rescan(vaultID: vault.id)
    #expect(try inode() == before)                       // atomic rewrite would have replaced the file
    #expect(try lib.catalog.instanceHashPaths(vaultID: vault.id).map(\.relPath).sorted() == rowsBefore)

    try FileManager.default.removeItem(at: vault.absoluteURL(forRelativePath: "a/two.jpg"))
    try makeJPEG(at: vault.absoluteURL(forRelativePath: "c/four.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:04", lat: nil, lon: nil)
    try await lib.rescan(vaultID: vault.id)
    #expect(try inode() != before)
    #expect(try lib.catalog.instanceHashPaths(vaultID: vault.id).map(\.relPath).sorted()
            == ["a/one.jpg", "b/three.jpg", "c/four.jpg"])
    #expect(try Manifest.read(from: vault.manifestURL).map(\.path).sorted()
            == ["a/one.jpg", "b/three.jpg", "c/four.jpg"])
}
