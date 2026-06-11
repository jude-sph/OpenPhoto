import Testing
@testable import OpenPhotoCore

@Test func rankerExactTextBeforeSemanticWithinStructured() {
    let structured = ["a", "b", "c", "d"]
    let text = ["c"]                                  // exact textual match
    let semantic = [("d", Float(0.9)), ("a", Float(0.7)), ("z", Float(0.5))]  // z not in structured
    let out = SearchRanker.combine(structured: structured, text: text,
                                   semantic: semantic, hasText: true)
    #expect(out == ["c", "d", "a"])   // text first; then semantic by score; z filtered out; no dup
}

@Test func rankerEmptyBoxPassesStructuredThrough() {
    let out = SearchRanker.combine(structured: ["a", "b"], text: [],
                                   semantic: [], hasText: false)
    #expect(out == ["a", "b"])
}

@Test func rankerDedupsAcrossLanes() {
    let out = SearchRanker.combine(structured: ["a", "b"], text: ["a"],
                                   semantic: [("a", 0.9), ("b", 0.8)], hasText: true)
    #expect(out == ["a", "b"])        // a appears once (text), then b (semantic)
}
