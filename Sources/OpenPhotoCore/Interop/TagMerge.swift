import Foundation

/// 3-way set merge for two-way tag sync. A tag survives iff it wasn't removed on either side; a tag is
/// added iff it appeared on either side relative to the baseline. `removed` and `added` never overlap
/// (a tag can't be both in-baseline-and-removed and not-in-baseline-and-added), so the result is
/// unambiguous — no conflicts to resolve. Pure + unit-tested.
public enum TagMerge {
    public static func merge(baseline: Set<String>, openphoto: Set<String>, finder: Set<String>) -> Set<String> {
        let removed = baseline.subtracting(openphoto).union(baseline.subtracting(finder))
        let added   = openphoto.subtracting(baseline).union(finder.subtracting(baseline))
        return baseline.subtracting(removed).union(added)
    }
}
