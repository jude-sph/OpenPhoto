import Foundation

/// What counts as a believable capture date, and how an already-parsed one is accepted or rejected.
///
/// Media files lie. A camera with a dead clock, or a camera app that writes milliseconds into
/// QuickTime's seconds-wide creation field, yields an embedded date thousands of years out — and
/// crucially it *parses cleanly*, so nothing downstream notices. `FilenameDate` has always
/// range-validated for exactly this reason; this is the same guard for dates that arrive already
/// parsed: embedded QuickTime/EXIF, and foreign (Takeout) sidecars.
public enum CaptureDate {
    /// Believable capture years — the bounds `FilenameDate` has always enforced, shared so there is
    /// one definition. Digital photos don't predate 1990, and anything past 2099 is a broken clock.
    public static let plausibleYears = 1990...2099

    public static func isPlausible(_ date: Date, calendar: Calendar = .current) -> Bool {
        plausibleYears.contains(calendar.component(.year, from: date))
    }

    /// The capture date to keep: an embedded date wins ONLY if it's believable. Otherwise the
    /// provisional stands — a filename stamp (already range-validated) or the file's mtime. An
    /// approximately-right date beats a confidently-wrong one, and it keeps the asset in the part
    /// of the timeline the user actually browses.
    public static func resolve(embedded: Date?, provisional: Date,
                               calendar: Calendar = .current) -> Date {
        guard let embedded, isPlausible(embedded, calendar: calendar) else { return provisional }
        return embedded
    }

    /// A capture date from a bare epoch number of ambiguous unit. Google Takeout documents
    /// `photoTakenTime.timestamp` as epoch SECONDS, but some exports emit MILLISECONDS; the two are
    /// unambiguous by magnitude, since a millisecond value read as seconds lands tens of thousands
    /// of years out. Returns nil when neither reading is believable, so the caller falls back to
    /// whatever it had.
    public static func fromEpoch(_ raw: TimeInterval, calendar: Calendar = .current) -> Date? {
        for candidate in [Date(timeIntervalSince1970: raw),
                          Date(timeIntervalSince1970: raw / 1000)] {
            if isPlausible(candidate, calendar: calendar) { return candidate }
        }
        return nil
    }
}
