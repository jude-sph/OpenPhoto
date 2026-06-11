import Testing
import Foundation
@testable import OpenPhotoCore

@Test func burstGroupsByTimeAndSimilarity() {
    let v1: [Float] = [1, 0, 0], v2: [Float] = [0.99, 0.14, 0], vDiff: [Float] = [0, 1, 0]
    let items: [(hash: String, takenAtMs: Int64, vector: [Float])] = [
        ("a", 0, v1), ("b", 2_000, v2), ("c", 5_000, v1),
        ("e", 6_000, vDiff),
        ("d", 3_600_000, v1),
    ]
    let groups = BurstGrouper.group(items, windowMs: 10_000, cosineThreshold: 0.9)
    #expect(groups.count == 1)
    #expect(Set(groups[0]) == ["a", "b", "c"])
}

@Test func duplicateGroupsWithinSameFolderOnly() {
    let items: [(hash: String, dirPath: String, value: Int64)] = [
        ("a", "trip", 0b0000),
        ("b", "trip", 0b0001),
        ("c", "other", 0b0000),
        ("d", "trip", Int64(bitPattern: ~0)),
    ]
    let groups = DuplicateGrouper.group(items, hammingThreshold: 4)
    #expect(groups.count == 1)
    #expect(Set(groups[0]) == ["a", "b"])
}

@Test func duplicateSiblingFolderSafe() {
    let items: [(hash: String, dirPath: String, value: Int64)] = [
        ("a", "2025", 0), ("b", "2025x", 0),
    ]
    #expect(DuplicateGrouper.group(items, hammingThreshold: 4).isEmpty)
}

@Test func keeperDuplicatesPrefersHighestResolution() {
    let c = [
        KeeperSelector.Candidate(hash: "small", pixelCount: 1000, fileSize: 50, favorite: false, rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "big",   pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: nil),
    ]
    let s = KeeperSelector.suggestion(c, mode: .duplicates)
    #expect(s.keep == "big")
    #expect(s.evict == ["small"])
}

@Test func keeperBurstsPrefersSharpest() {
    let c = [
        KeeperSelector.Candidate(hash: "blur",  pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: 5),
        KeeperSelector.Candidate(hash: "sharp", pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: 50),
    ]
    let s = KeeperSelector.suggestion(c, mode: .bursts)
    #expect(s.keep == "sharp")
    #expect(s.evict == ["blur"])
}

@Test func keeperProtectsFavoritesAndRated() {
    let c = [
        KeeperSelector.Candidate(hash: "keep", pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "fav",  pixelCount: 1000, fileSize: 10, favorite: true,  rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "rated",pixelCount: 1000, fileSize: 10, favorite: false, rating: 4, sharpness: nil),
        KeeperSelector.Candidate(hash: "drop", pixelCount: 1000, fileSize: 10, favorite: false, rating: 0, sharpness: nil),
    ]
    let s = KeeperSelector.suggestion(c, mode: .duplicates)
    #expect(s.keep == "keep")
    #expect(Set(s.evict) == ["drop"])
}
