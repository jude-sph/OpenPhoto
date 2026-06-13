import Foundation

/// Best-effort capture date parsed from a media filename. Used only as a fallback when the file
/// carries no embedded EXIF/QuickTime date — the filesystem mtime is unreliable (a copy/move resets
/// it), but phone and camcorder names usually stamp the real capture time. Recognises the common
/// forms: `20190101_000146`, `IMG_/VID_/PXL_YYYYMMDD_HHMMSS…`, WhatsApp `VID-YYYYMMDD-WA####`
/// (date only), and `2019-01-01 12.30.45` screenshots. Range-validated so it won't latch onto a
/// resolution like `1920x1080`, a sequence id, or an impossible date.
public enum FilenameDate {
    // YYYYMMDD with optional separators, optionally followed by HHMMSS (also optionally separated).
    private static let re = try! NSRegularExpression(pattern:
        #"(?<y>(?:19|20)\d{2})[-_.]?(?<mo>\d{2})[-_.]?(?<d>\d{2})(?:[-_T .]?(?<h>\d{2})[-_.:]?(?<mi>\d{2})[-_.:]?(?<s>\d{2}))?"#)

    public static func parse(_ filename: String, calendar: Calendar = .current) -> Date? {
        let ns = filename as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: filename, range: whole) {     // first match that range-validates
            func grp(_ name: String) -> Int? {
                let r = m.range(withName: name)
                guard r.location != NSNotFound else { return nil }
                return Int(ns.substring(with: r))
            }
            guard let y = grp("y"), let mo = grp("mo"), let d = grp("d"),
                  (1990...2099).contains(y), (1...12).contains(mo), (1...31).contains(d)
            else { continue }
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d
            if let h = grp("h"), let mi = grp("mi"), let s = grp("s"),
               (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) {
                c.hour = h; c.minute = mi; c.second = s
            } else {
                c.hour = 12   // date-only → noon, so a timezone shift can't bump it to an adjacent day
            }
            if let date = calendar.date(from: c) { return date }
        }
        return nil
    }
}
