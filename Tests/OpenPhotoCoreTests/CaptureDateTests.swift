import Testing
import Foundation
@testable import OpenPhotoCore

private let cal = Calendar.current

private func date(year: Int, month: Int = 6, day: Int = 1) -> Date {
    var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 12
    return cal.date(from: c)!
}

@Test func plausibleYearsBracketRealCaptureDates() {
    #expect(CaptureDate.isPlausible(date(year: 2016)))
    #expect(CaptureDate.isPlausible(date(year: 1990)))
    #expect(CaptureDate.isPlausible(date(year: 2099)))
    #expect(!CaptureDate.isPlausible(date(year: 1989)))
    #expect(!CaptureDate.isPlausible(date(year: 2100)))
}

// The two real-world failures: QuickTime creation dates read out of the .mp4 headers as years
// 51562 and 214742 (a camera app wrote milliseconds into a seconds-wide field).
@Test func absurdEmbeddedYearsAreRejected() {
    #expect(!CaptureDate.isPlausible(date(year: 51562)))
    #expect(!CaptureDate.isPlausible(date(year: 214742)))
}

@Test func resolveKeepsAPlausibleEmbeddedDate() {
    let embedded = date(year: 2016, month: 11, day: 19)
    let provisional = date(year: 2020)
    #expect(CaptureDate.resolve(embedded: embedded, provisional: provisional) == embedded)
}

@Test func resolveFallsBackWhenEmbeddedIsImplausible() {
    let provisional = date(year: 2016, month: 11, day: 18)
    #expect(CaptureDate.resolve(embedded: date(year: 51562), provisional: provisional) == provisional)
    #expect(CaptureDate.resolve(embedded: nil, provisional: provisional) == provisional)
}

// Google documents photoTakenTime.timestamp as seconds, but some exports emit milliseconds.
@Test func fromEpochAcceptsSecondsAndMilliseconds() throws {
    let asSeconds = try #require(CaptureDate.fromEpoch(1479500274))          // 2016-11-18
    #expect(cal.component(.year, from: asSeconds) == 2016)

    let asMillis = try #require(CaptureDate.fromEpoch(1479500274000))        // same instant, ms
    #expect(cal.component(.year, from: asMillis) == 2016)
    #expect(abs(asSeconds.timeIntervalSince(asMillis)) < 1)
}

@Test func fromEpochRejectsValuesImplausibleUnderEitherUnit() {
    // 6714466205584 is one of the real corrupt values: year 214742 as seconds, 2182 as millis.
    #expect(CaptureDate.fromEpoch(6714466205584) == nil)
    #expect(CaptureDate.fromEpoch(0) == nil)                                 // 1970, pre-digital
}
