import Foundation
import OpenPhotoCore

extension DatePreset {
    /// Menu display label.
    var label: String {
        switch self {
        case .today:      return "Today"
        case .last7Days:  return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .last90Days: return "Last 90 days"
        case .thisYear:   return "This year"
        case .lastYear:   return "Last year"
        case .year(let y): return String(y)
        }
    }

    /// Relative presets for the Date menu.
    static let relative: [DatePreset] = [.today, .last7Days, .last30Days, .last90Days, .thisYear, .lastYear]

    /// Specific calendar years for the menu — starts two years back, since `.thisYear`/`.lastYear`
    /// already cover the two most recent (avoids the duplicate/overlap the review flagged).
    static func recentYears(asOf now: Date, count: Int = 5, calendar: Calendar = .current) -> [DatePreset] {
        let current = calendar.component(.year, from: now)
        return (0..<count).map { .year(current - 2 - $0) }
    }
}
