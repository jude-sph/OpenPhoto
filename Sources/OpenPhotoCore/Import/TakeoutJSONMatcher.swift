import Foundation

/// Finds the Google Takeout JSON sidecar for a media file. Google's naming is
/// inconsistent across export versions (the 2024+ `.supplemental-metadata.json`
/// suffix, ~46-char truncation, and a `(n)` counter that hops to after the
/// extension), so we try an ordered list of candidates and take the first that exists.
public enum TakeoutJSONMatcher {
    /// Ordered candidate JSON filenames for a given media filename.
    public static func candidateJSONNames(forMediaFilename name: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }

        let suffixes = [".json", ".supplemental-metadata.json", ".supplemental-met.json", ".suppl.json"]
        for s in suffixes { add(name + s) }

        // Counter quirk: "base(n).ext" → JSON "base.ext(n).json".
        if let paren = name.range(of: #"\(\d+\)"#, options: .regularExpression),
           name[paren.upperBound...].first == "." || paren.upperBound == name.endIndex {
            let n = String(name[paren])                                   // "(1)"
            let base = String(name[name.startIndex..<paren.lowerBound])   // "IMG_1234"
            let ext = String(name[paren.upperBound...])                   // ".JPG" or ""
            add(base + ext + n + ".json")                                 // "IMG_1234.JPG(1).json"
            add(base + ext + n + ".supplemental-metadata.json")
        }

        // Truncation: Google caps the JSON base name (~46 chars).
        if name.count > 46 {
            add(String(name.prefix(46)) + ".json")
            add(String(name.prefix(46)) + ".supplemental-metadata.json")
        }
        return out
    }

    /// First existing JSON sidecar for `name` in `dir`, or nil.
    public static func jsonURL(forMediaNamed name: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        for candidate in candidateJSONNames(forMediaFilename: name) {
            let url = dir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
