import Testing
import Foundation
@testable import OpenPhotoCore

@Test func dateLenientAcceptsFractionalAndPlain() {
    #expect(ISO8601Millis.dateLenient(from: "2022-10-07T14:23:01.000Z") != nil)   // fractional (app's own)
    #expect(ISO8601Millis.dateLenient(from: "2022-10-07T14:23:01Z") != nil)        // plain
    #expect(ISO8601Millis.dateLenient(from: "not a date") == nil)
}

@Test func dateLenientRoundTripsTheAppsOwnOutput() {
    let s = ISO8601Millis.string(from: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(ISO8601Millis.dateLenient(from: s) != nil)   // string() writes fractional; lenient must parse it
}
