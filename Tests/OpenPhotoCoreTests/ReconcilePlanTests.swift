import Testing
import Foundation
@testable import OpenPhotoCore

// The reconcile diff is a PURE function over two sets of (hash, path) placements → the concrete actions
// that make a drive match the library. Every case from the design's testing checklist is a table test.

private func P(_ hash: String, _ path: String) -> Placement { Placement(hash: hash, path: path) }
private func plan(desired: [Placement], actual: [Placement]) -> ReconcilePlan {
    computeReconcilePlan(desired: Set(desired), actual: Set(actual))
}

// Idempotence: a drive already matching the library yields an empty plan.
@Test func emptyWhenDriveMatchesLibrary() {
    let d = [P("h1", "a/1.jpg"), P("h2", "b/2.jpg")]
    let p = plan(desired: d, actual: d)
    #expect(p.isEmpty)
}

// A clean move: content sits at the old path on the drive, the library wants it only at the new path →
// relocate, no copy, no delete.
@Test func cleanMoveRelocates() {
    let p = plan(desired: [P("h1", "new/1.jpg")], actual: [P("h1", "old/1.jpg")])
    #expect(p.relocations == [ReconcilePlan.Relocation(hash: "h1", from: "old/1.jpg", to: "new/1.jpg")])
    #expect(p.copies.isEmpty && p.staleRemovals.isEmpty && p.reviewDeletions.isEmpty)
}

// New content the drive doesn't have at all → copy it in.
@Test func newContentCopies() {
    let p = plan(desired: [P("h1", "a/1.jpg")], actual: [])
    #expect(p.copies == [P("h1", "a/1.jpg")])
    #expect(p.relocations.isEmpty && p.staleRemovals.isEmpty && p.reviewDeletions.isEmpty)
}

// A hash GONE from the library entirely → a genuine deletion, review-gated (never auto-removed).
@Test func hashGoneFromLibraryIsReviewDeletion() {
    let p = plan(desired: [P("keep", "a/1.jpg")],
                 actual:  [P("keep", "a/1.jpg"), P("gone", "a/old.jpg")])
    #expect(p.reviewDeletions == [P("gone", "a/old.jpg")])
    #expect(p.copies.isEmpty && p.relocations.isEmpty && p.staleRemovals.isEmpty)
}

// THE apple-photos phantom: the same content is on the drive at BOTH the old path and the desired new
// path; the library wants it only at the new path → the old path is a stale removal (content is safe at
// the new path), NOT a deletion.
@Test func phantomOldPathIsStaleRemovalNotDeletion() {
    let p = plan(desired: [P("h1", "Import Staging/x.jpg")],
                 actual:  [P("h1", "Import Staging/x.jpg"), P("h1", "Recently/x.jpg")])
    #expect(p.staleRemovals == [P("h1", "Recently/x.jpg")])
    #expect(p.reviewDeletions.isEmpty && p.copies.isEmpty && p.relocations.isEmpty)
}

// Multi-placement (albums-as-folders): one hash desired at several paths, present at one → the extra
// desired placements are copies (duplicated from the on-drive copy).
@Test func multiPlacementCopiesTheExtras() {
    let p = plan(desired: [P("h1", "a/1.jpg"), P("h1", "b/1.jpg"), P("h1", "c/1.jpg")],
                 actual:  [P("h1", "a/1.jpg")])
    #expect(Set(p.copies) == [P("h1", "b/1.jpg"), P("h1", "c/1.jpg")])
    #expect(p.relocations.isEmpty && p.staleRemovals.isEmpty && p.reviewDeletions.isEmpty)
}

// Several wrong paths for a hash that's wanted at several other paths → pair them up as relocations.
@Test func multipleWrongPathsPairAsRelocations() {
    let p = plan(desired: [P("h1", "a/1.jpg"), P("h1", "b/1.jpg")],
                 actual:  [P("h1", "x/1.jpg"), P("h1", "y/1.jpg")])
    // Deterministic pairing (sorted needed zipped with sorted surplus).
    #expect(p.relocations == [
        ReconcilePlan.Relocation(hash: "h1", from: "x/1.jpg", to: "a/1.jpg"),
        ReconcilePlan.Relocation(hash: "h1", from: "y/1.jpg", to: "b/1.jpg"),
    ])
    #expect(p.copies.isEmpty && p.staleRemovals.isEmpty && p.reviewDeletions.isEmpty)
}

// Surplus wrong-path copies beyond what's needed (hash still desired at a retained path) → stale removals.
@Test func surplusWrongPathsAreStaleRemovals() {
    let p = plan(desired: [P("h1", "a/1.jpg")],
                 actual:  [P("h1", "a/1.jpg"), P("h1", "x/1.jpg"), P("h1", "y/1.jpg")])
    #expect(Set(p.staleRemovals) == [P("h1", "x/1.jpg"), P("h1", "y/1.jpg")])
    #expect(p.copies.isEmpty && p.relocations.isEmpty && p.reviewDeletions.isEmpty)
}

// Fewer wrong paths than needed placements → each wrong path relocates, the remainder are copies.
@Test func fewerWrongPathsThanNeededMixesRelocateAndCopy() {
    let p = plan(desired: [P("h1", "a/1.jpg"), P("h1", "b/1.jpg"), P("h1", "c/1.jpg")],
                 actual:  [P("h1", "x/1.jpg")])
    #expect(p.relocations == [ReconcilePlan.Relocation(hash: "h1", from: "x/1.jpg", to: "a/1.jpg")])
    #expect(Set(p.copies) == [P("h1", "b/1.jpg"), P("h1", "c/1.jpg")])
    #expect(p.staleRemovals.isEmpty && p.reviewDeletions.isEmpty)
}

// Independent hashes are handled independently and unioned.
@Test func independentHashesCombine() {
    let p = plan(
        desired: [P("move", "new/m.jpg"), P("new", "n.jpg"), P("keep", "k.jpg")],
        actual:  [P("move", "old/m.jpg"), P("keep", "k.jpg"), P("del", "d.jpg")])
    #expect(p.relocations == [ReconcilePlan.Relocation(hash: "move", from: "old/m.jpg", to: "new/m.jpg")])
    #expect(p.copies == [P("new", "n.jpg")])
    #expect(p.reviewDeletions == [P("del", "d.jpg")])
    #expect(p.staleRemovals.isEmpty)
}

// Blast-radius: the fraction of the drive a plan would REMOVE (stale + review) — the guard input.
@Test func removalFractionCountsStaleAndReview() {
    let p = ReconcilePlan(
        copies: [P("h", "c.jpg")],
        relocations: [],
        staleRemovals: [P("h", "s1.jpg"), P("h", "s2.jpg")],
        reviewDeletions: [P("h", "r.jpg")])
    // 3 removals (2 stale + 1 review) over an actual of 10 files → 0.3
    #expect(p.removalFraction(actualCount: 10) == 0.3)
    #expect(ReconcilePlan(copies: [], relocations: [], staleRemovals: [], reviewDeletions: [])
                .removalFraction(actualCount: 0) == 0)
}
