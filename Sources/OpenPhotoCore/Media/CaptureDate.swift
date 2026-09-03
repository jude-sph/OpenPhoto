import Foundation

/// What counts as a believable capture date, and how an already-parsed one is accepted or rejected.
///
/// Media files lie. A camera with a dead clock, or a camera app that writes milliseconds into
/// QuickTime's seconds-wide creation field, yields an embedded date thousands of years out — and
/// crucially it *parses cleanly*, so nothing downstream notices. `FilenameDate` has always
/// range-validated for exactly this reason; this is the same guard for dates that arrive already
/// parsed: embedded QuickTime/EXIF, and foreign (Takeout) sidecars.
public enum CaptureDate {
    /// Believable capture years, by what the medium can actually be. A scanned family photo carries
    /// a real archive date and must survive; consumer digital video simply doesn't predate ~1990, so
    /// a 1947 .mp4 is always a broken clock. Anything past 2099 is a broken clock either way.
    ///
    /// Deliberately more generous than `FilenameDate`'s own 1990 floor: that one is pattern-matching
    /// digit runs, where an old-looking year is far likelier to be coincidence than a real stamp.
    /// A date embedded in the file is an explicit assertion, so it earns the benefit of the doubt.
    public static func plausibleYears(for kind: MediaKind) -> ClosedRange<Int> {
        switch kind {
        case .photo: return 1826...2099   // the first surviving photograph
        case .video: return 1990...2099
        }
    }

    public static func isPlausible(_ date: Date, kind: MediaKind = .photo,
                                   calendar: Calendar = .current) -> Bool {
        plausibleYears(for: kind).contains(calendar.component(.year, from: date))
    }

    /// The capture date to keep: an embedded date wins ONLY if it's believable. Otherwise the
    /// provisional stands — a filename stamp (already range-validated) or the file's mtime. An
    /// approximately-right date beats a confidently-wrong one, and it keeps the asset in the part
    /// of the timeline the user actually browses.
    public static func resolve(embedded: Date?, provisional: Date, kind: MediaKind = .photo,
                               calendar: Calendar = .current) -> Date {
        guard let embedded, isPlausible(embedded, kind: kind, calendar: calendar)
        else { return provisional }
        return embedded
    }

    /// A capture date from a bare epoch number of ambiguous unit. Google Takeout documents
    /// `photoTakenTime.timestamp` as epoch SECONDS, but some exports emit MILLISECONDS; the two are
    /// unambiguous by magnitude, since a millisecond value read as seconds lands tens of thousands
    /// of years out. Returns nil when neither reading is believable, so the caller falls back to
    /// whatever it had.
    public static func fromEpoch(_ raw: TimeInterval, kind: MediaKind = .photo,
                                 calendar: Calendar = .current) -> Date? {
        for candidate in [Date(timeIntervalSince1970: raw),
                          Date(timeIntervalSince1970: raw / 1000)] {
            if isPlausible(candidate, kind: kind, calendar: calendar) { return candidate }
        }
        return nil
    }
}
