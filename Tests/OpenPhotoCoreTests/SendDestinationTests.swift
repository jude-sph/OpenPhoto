import Testing
import Foundation
@testable import OpenPhotoCore

@Test func fingerprintLooseMatchIgnoresSubSecondAndHash() {
    let a = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_500, hash: "sha256:aaa")
    let b = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_900, hash: nil)  // same second
    let c = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_001_500, hash: nil)  // next second
    let d = PresenceFingerprint(size: 101, captureDateMs: 1_700_000_000_500, hash: nil)  // diff size
    #expect(a.looselyMatches(b))     // size + same capture second
    #expect(!a.looselyMatches(c))    // different second
    #expect(!a.looselyMatches(d))    // different size
}

@Test func fingerprintWithUnknownDateNeverMatches() {
    let known = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_000, hash: nil)
    let unknownA = PresenceFingerprint(size: 100, captureDateMs: 0, hash: nil)
    let unknownB = PresenceFingerprint(size: 100, captureDateMs: 0, hash: nil)
    #expect(!unknownA.looselyMatches(known))     // unknown date never matches a known one
    #expect(!unknownA.looselyMatches(unknownB))  // two unknown dates of same size don't match
}
