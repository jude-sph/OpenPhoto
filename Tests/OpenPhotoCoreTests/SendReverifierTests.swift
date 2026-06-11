import Testing
@testable import OpenPhotoCore

private func sent(_ hash: String, key: String = "cam-Z",
                  size: Int64, captureMs: Int64) -> SendRegistry.Entry {
    SendRegistry.Entry(hash: hash, destinationKey: key, deviceName: "iPhone", deviceKind: "phone",
        sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: size, fpCaptureDateMs: captureMs)
}
private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

@Test func reconcilePresentAndGoneByFingerprint() {
    let entries = [sent(A, size: 1000, captureMs: 1_700_000_000_000),
                   sent(B, size: 2000, captureMs: 1_700_000_500_000)]
    // The phone now lists only A's fingerprint (sub-second drift tolerated by capture-second match).
    let present = [PresenceFingerprint(size: 1000, captureDateMs: 1_700_000_000_400, hash: nil)]
    let v = SendReverifier().reconcile(entries: entries, present: present)
    #expect(v[A] == .present)
    #expect(v[B] == .gone)
}

@Test func volumeMatchesOnAuthoritativeHash() {
    let entries = [sent(A, key: "vol-U", size: 10, captureMs: 0)]   // capture date unknown (0)
    let present = [PresenceFingerprint(size: 10, captureDateMs: 0, hash: A)]  // volume exposes the hash
    #expect(SendReverifier().reconcile(entries: entries, present: present)[A] == .present)
}

@Test func emptyListingMarksEverythingGone() {
    #expect(SendReverifier().reconcile(entries: [sent(A, size: 1, captureMs: 1)], present: [])[A] == .gone)
}

@Test func noEntriesIsEmpty() {
    #expect(SendReverifier().reconcile(entries: [], present:
        [PresenceFingerprint(size: 1, captureDateMs: 1, hash: nil)]).isEmpty)
}

@Test func unknownCaptureDatePhoneEntryIsGone() {
    // No hash (phone) AND captureMs == 0 → looselyMatches's 0-date guard blocks the match → gone.
    let entries = [sent(A, size: 5, captureMs: 0)]
    let present = [PresenceFingerprint(size: 5, captureDateMs: 1_700_000_000_000, hash: nil)]
    #expect(SendReverifier().reconcile(entries: entries, present: present)[A] == .gone)
}
