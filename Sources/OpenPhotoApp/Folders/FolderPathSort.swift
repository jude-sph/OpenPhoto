import Foundation

extension Sequence where Element == String {
    /// Folder paths in the order a person expects in a menu: alphabetical the way Finder sorts
    /// (case-insensitive, "Trip 2" before "Trip 10"), compared folder by folder so a folder's
    /// subfolders sit directly under it. Plain `sorted()` compares raw characters, which put every
    /// capitalised name before every lower-case one and let "A B" split "A" from "A/child".
    func sortedAsFolderPaths() -> [String] {
        let keyed = map { (path: $0, parts: $0.split(separator: "/").map(String.init)) }
        return keyed.sorted { l, r in
            for (a, b) in zip(l.parts, r.parts) {
                switch a.localizedStandardCompare(b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return l.parts.count < r.parts.count   // a parent (and the root "") before its children
        }.map(\.path)
    }
}
