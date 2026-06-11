import Testing
import Foundation
@testable import OpenPhotoCore

@Test func emptyFiltersIsEmpty() {
    #expect(SearchFilters().isEmpty)
}

@Test func anyActiveFacetIsNotEmpty() {
    var f = SearchFilters(); f.includePeople = [1]
    #expect(!f.isEmpty)
    var g = SearchFilters(); g.hasText = true
    #expect(!g.isEmpty)
    var h = SearchFilters(); h.excludeFolders = ["a"]
    #expect(!h.isEmpty)
    var i = SearchFilters(); i.foldersRecursive = false
    #expect(i.isEmpty)
}

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

@Test func datePresetSpecificYearSpansThatYear() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let r = DatePreset.year(2019).range(asOf: now, calendar: cal)
    #expect(r.lowerBound == cal.date(from: DateComponents(year: 2019, month: 1, day: 1))!)
    #expect(r.upperBound < cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!)
    #expect(r.upperBound >= cal.date(from: DateComponents(year: 2019, month: 12, day: 31))!)
}

@Test func datePresetThisYearAndLastYear() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let thisY = DatePreset.thisYear.range(asOf: now, calendar: cal)
    #expect(thisY.lowerBound == cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
    let lastY = DatePreset.lastYear.range(asOf: now, calendar: cal)
    #expect(lastY.lowerBound == cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!)
    #expect(lastY.upperBound < cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
}

@Test func datePresetLast7DaysSpansSevenCalendarDays() {
    let cal = utc(); let now = date(2026, 6, 11, cal)
    let r = DatePreset.last7Days.range(asOf: now, calendar: cal)
    #expect(r.lowerBound == cal.startOfDay(for: date(2026, 6, 5, cal)))
    #expect(r.upperBound == now)
}
