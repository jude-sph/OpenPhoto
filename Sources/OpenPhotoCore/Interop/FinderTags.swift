import Foundation

/// Read/write a file's macOS Finder tags (the `com.apple.metadata:_kMDItemUserTags` xattr) via
/// Foundation's `URLResourceValues.tagNames` — plain label strings (Finder tag *colours* are not
/// represented here and are out of scope). Non-destructive: tags live in the resource fork, so the
/// data fork (and the content hash) is unchanged.
public enum FinderTags {
    /// Reserved Finder tag mirroring OpenPhoto's per-photo favourite flag. It is NOT selectable as a
    /// normal OpenPhoto tag — it's driven by the favourite (heart) toggle and synced two-way with this
    /// Finder tag, so favouriting in the app shows up in Finder and vice-versa.
    public static let favoriteTagName = "Favourite"

    public static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }
    public static func write(_ tags: [String], to url: URL) throws {
        // `URLResourceValues.tagNames` is get-only on macOS Foundation; the writable path is
        // `NSURL.setResourceValue(_:forKey:)` with `.tagNamesKey`.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
