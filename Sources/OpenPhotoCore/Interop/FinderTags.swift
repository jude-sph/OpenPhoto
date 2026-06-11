import Foundation

/// Read/write a file's macOS Finder tags (the `com.apple.metadata:_kMDItemUserTags` xattr) via
/// Foundation's `URLResourceValues.tagNames` — plain label strings (Finder tag *colours* are not
/// represented here and are out of scope). Non-destructive: tags live in the resource fork, so the
/// data fork (and the content hash) is unchanged.
public enum FinderTags {
    public static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    public static func write(_ tags: [String], to url: URL) throws {
        // `URLResourceValues.tagNames` is get-only on macOS Foundation; the writable path is
        // `NSURL.setResourceValue(_:forKey:)` with `.tagNamesKey`.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
