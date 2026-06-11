import Foundation

/// A relative date filter that resolves to a concrete `ClosedRange<Date>` at pick-time, so the
/// search itself stays deterministic. `now` is injected for testability.
public enum DatePreset: Sendable, Equatable {
    case today, last7Days, last30Days, last90Days, thisYear, lastYear
    case year(Int)

    public func range(asOf now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: startOfToday)! }
        switch self {
        case .today:      return startOfToday...now
        case .last7Days:  return daysAgo(6)...now
        case .last30Days: return daysAgo(29)...now
        case .last90Days: return daysAgo(89)...now
        case .thisYear:   return DatePreset.year(calendar.component(.year, from: now)).range(asOf: now, calendar: calendar)
        case .lastYear:   return DatePreset.year(calendar.component(.year, from: now) - 1).range(asOf: now, calendar: calendar)
        case .year(let y):
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
            let startNext = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1))!
            return start...startNext.addingTimeInterval(-0.001)
        }
    }
}
