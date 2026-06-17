import Testing
import Foundation
@testable import OpenPhotoCore

private func cand(_ path: String, _ kind: MediaKind, taken: TimeInterval,
                  cid: String? = nil, dur: Double? = nil) -> LivePhotoPairer.Candidate {
    // Distinct fake hash per path (only used as an identity string in tests).
    let fake = String((path.replacingOccurrences(of: "/", with: "_")
        + String(repeating: "0", count: 64)).prefix(64))
    return .init(hash: ContentHash(stringValue: "sha256:" + fake),
                 relPath: path, kind: kind,
                 takenAt: Date(timeIntervalSince1970: taken), contentIdentifier: cid,
                 durationSeconds: dur)
}

@Test func pairsByContentIdentifier() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_1.heic", .photo, taken: 0, cid: "CID-1"),
        cand("a/IMG_1.mov", .video, taken: 0, cid: "CID-1"),
        cand("a/IMG_2.heic", .photo, taken: 50, cid: "CID-2"),
    ])
    #expect(pairs.count == 1)
    #expect(pairs[0].photoRelPath == "a/IMG_1.heic")
    #expect(pairs[0].videoRelPath == "a/IMG_1.mov")
}

@Test func pairsByBasenameAndTimeWhenNoCid() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_3.heic", .photo, taken: 100),
        cand("a/IMG_3.mov", .video, taken: 101),   // within 2s
    ])
    #expect(pairs.count == 1)
}

@Test func doesNotPairLongVideoSharingBasename() {
    // A 7-minute video that merely shares a still's basename is NOT Live Photo motion — the
    // basename fallback must reject it so it stays visible in the timeline (regression: it was
    // wrongly folded into the photo and hidden).
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_4004.heic", .photo, taken: 0),
        cand("a/IMG_4004.mov", .video, taken: 0, dur: 436.0),
    ])
    #expect(pairs.isEmpty)
}

@Test func pairsShortVideoSharingBasename() {
    // A genuine Live Photo motion clip (short) still pairs by basename.
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_9.heic", .photo, taken: 0),
        cand("a/IMG_9.mov", .video, taken: 0, dur: 3.0),
    ])
    #expect(pairs.count == 1)
}

@Test func longVideoStillPairsByContentIdentifier() {
    // The duration guard only gates the basename fallback; an authoritative content-id match
    // (which a coincidental long video never has) is unaffected.
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_10.heic", .photo, taken: 0, cid: "CID-X"),
        cand("a/IMG_10.mov", .video, taken: 0, cid: "CID-X", dur: 999.0),
    ])
    #expect(pairs.count == 1)
}

@Test func doesNotPairAcrossFolders() {
    // Same basename but different folders → not a pair.
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_4.heic", .photo, taken: 0),
        cand("b/IMG_4.mov", .video, taken: 0),
    ])
    #expect(pairs.isEmpty)
}

@Test func pairsSameBasenameRegardlessOfTime() {
    // Imported Live Photos: the .mov's metadata time is often far off the photo's,
    // so same-folder + same-basename pairs even when timestamps differ widely.
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_5.heic", .photo, taken: 0),
        cand("a/IMG_5.mov", .video, taken: 99999),
    ])
    #expect(pairs.count == 1)
    #expect(pairs[0].photoRelPath == "a/IMG_5.heic")
}
