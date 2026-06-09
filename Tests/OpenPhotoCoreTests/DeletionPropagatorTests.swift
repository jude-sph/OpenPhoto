import Testing
import Foundation
@testable import OpenPhotoCore

private func presence(_ hash: String, _ drivePath: String) -> VaultPresenceEntry {
    VaultPresenceEntry(hash: hash, relPath: drivePath, dirPath: "x", size: 1, driveRelPath: drivePath)
}

@Test func eligibleAppliesTheThreePartRule() {
    let onMac    = "sha256:" + String(format: "%064d", 1)   // deleted but a duplicate local copy remains
    let gone     = "sha256:" + String(format: "%064d", 2)   // deleted, no local copy, on drive  → ELIGIBLE
    let notDrive = "sha256:" + String(format: "%064d", 3)   // deleted, no local copy, NOT on drive
    let q: [PendingDeletionRecord] = [
        .init(hash: onMac, relPath: "a/1.jpg", deletedAtMs: 1),
        .init(hash: gone, relPath: "a/2.jpg", deletedAtMs: 2),
        .init(hash: notDrive, relPath: "a/3.jpg", deletedAtMs: 3),
    ]
    let local: Set<String> = [onMac]                              // only onMac still has a local instance
    let pres = [presence(onMac, "P/a/1.jpg"), presence(gone, "P/a/2.jpg")]

    let result = DeletionPropagator().eligible(queue: q, localHashes: local, presence: pres)

    #expect(result.map(\.hash) == [gone])
    #expect(result.first?.driveRelPath == "P/a/2.jpg")
    #expect(result.first?.deletedAtMs == 2)   // deletedAtMs comes from the queue record, not presence
}

@Test func eligibleExcludesWhenLocalCopyRemainsEvenIfNotOnDrive() {
    // A deleted-but-still-local hash that isn't on the drive must be excluded by the
    // no-local guard alone (it never reaches the presence lookup).
    let localNotDrive = "sha256:" + String(format: "%064d", 7)
    let result = DeletionPropagator().eligible(
        queue: [.init(hash: localNotDrive, relPath: "a/7.jpg", deletedAtMs: 1)],
        localHashes: [localNotDrive], presence: [])
    #expect(result.isEmpty)
}

@Test func eligibleEmptyWhenQueueEmptyOrNothingOnDrive() {
    let h = "sha256:" + String(format: "%064d", 9)
    #expect(DeletionPropagator().eligible(queue: [], localHashes: [], presence: [presence(h, "p")]).isEmpty)
    #expect(DeletionPropagator().eligible(
        queue: [.init(hash: h, relPath: "a", deletedAtMs: 1)],
        localHashes: [], presence: []).isEmpty)
}
