import Foundation

public enum DrivePathMap {
    /// Map a drive-relative path to the Mac folder structure by stripping a leading path
    /// component that matches a configured source-vault basename (the drive mirrors Mac roots
    /// by basename). Non-matching prefixes (and root-level files) are returned unchanged.
    public static func driveToMacRelPath(_ driveRelPath: String, sourceBasenames: [String]) -> String {
        let comps = driveRelPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if comps.count == 2, sourceBasenames.contains(String(comps[0])) {
            return String(comps[1])
        }
        return driveRelPath
    }
}
