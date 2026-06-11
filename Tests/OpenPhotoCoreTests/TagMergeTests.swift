import Testing
import Foundation
@testable import OpenPhotoCore

@Test func tagMergeAddOnOneSidePropagates() {
    #expect(TagMerge.merge(baseline: ["a"], openphoto: ["a", "b"], finder: ["a"]) == ["a", "b"])
}
@Test func tagMergeRemoveOnOneSidePropagates() {
    #expect(TagMerge.merge(baseline: ["a", "b"], openphoto: ["a", "b"], finder: ["a"]) == ["a"])
}
@Test func tagMergeAddAndRemoveOppositeSides() {
    #expect(TagMerge.merge(baseline: ["a", "b"], openphoto: ["a", "b", "c"], finder: ["b"]) == ["b", "c"])
}
@Test func tagMergeEmptyBaselineIsAdditive() {
    #expect(TagMerge.merge(baseline: [], openphoto: ["a"], finder: ["b"]) == ["a", "b"])
}
@Test func tagMergeNoOpWhenAllEqual() {
    #expect(TagMerge.merge(baseline: ["a"], openphoto: ["a"], finder: ["a"]) == ["a"])
}

@Test func finderTagsRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let f = t.root.appendingPathComponent("x.txt")
    try Data("x".utf8).write(to: f)
    #expect(FinderTags.read(f) == [])
    try FinderTags.write(["beach", "summer"], to: f)
    #expect(Set(FinderTags.read(f)) == ["beach", "summer"])
    try FinderTags.write(["beach"], to: f)                 // removal overwrite
    #expect(FinderTags.read(f) == ["beach"])
    try FinderTags.write([], to: f)                        // clear
    #expect(FinderTags.read(f) == [])
}
