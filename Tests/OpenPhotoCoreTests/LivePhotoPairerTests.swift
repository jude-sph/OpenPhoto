import Testing
import Foundation
@testable import OpenPhotoCore

private func cand(_ path: String, _ kind: MediaKind, taken: TimeInterval,
                  cid: String? = nil) -> LivePhotoPairer.Candidate {
    // Distinct fake hash per path (only used as an identity string in tests).
    let fake = String((path.replacingOccurrences(of: "/", with: "_")
        + String(repeating: "0", count: 64)).prefix(64))
    return .init(hash: ContentHash(stringValue: "sha256:" + fake),
                 relPath: path, kind: kind,
                 takenAt: Date(timeIntervalSince1970: taken), contentIdentifier: cid)
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

@Test func doesNotPairAcrossFoldersOrBeyondTimeWindow() {
    let pairs = LivePhotoPairer.pair(candidates: [
        cand("a/IMG_4.heic", .photo, taken: 0),
        cand("b/IMG_4.mov", .video, taken: 0),      // other folder
        cand("a/IMG_5.heic", .photo, taken: 0),
        cand("a/IMG_5.mov", .video, taken: 10),     // 10s apart — unrelated video
    ])
    #expect(pairs.isEmpty)
}
