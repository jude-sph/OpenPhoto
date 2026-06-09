import Testing
import Foundation
@testable import OpenPhotoCore

@Test func enqueueDequeueAndListRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let h2 = "sha256:" + String(repeating: "2", count: 64)

    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 100)
    try cat.enqueuePendingDeletion(hash: h2, relPath: "paris/IMG_2.jpg", deletedAtMs: 200)
    // Re-enqueue same hash updates, never duplicates (PK = hash).
    try cat.enqueuePendingDeletion(hash: h1, relPath: "rome/IMG_1.jpg", deletedAtMs: 150)

    let all = try cat.pendingDeletions()
    #expect(all.count == 2)
    #expect(all.first?.hash == h2)                 // newest (deletedAtMs DESC)
    #expect(all.first(where: { $0.hash == h1 })?.deletedAtMs == 150)

    try cat.dequeuePendingDeletion(hash: h1)
    #expect(try cat.pendingDeletions().map(\.hash) == [h2])

    try cat.clearPendingDeletions(hashes: [h2])
    #expect(try cat.pendingDeletions().isEmpty)
    // Empty input is a no-op, never an error.
    try cat.clearPendingDeletions(hashes: [])
}
