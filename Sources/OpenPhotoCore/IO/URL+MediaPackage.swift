import Foundation

extension URL {
    /// True if this directory is an opaque package a media scan must NOT descend into — most
    /// importantly an Apple Photos library (`.photoslibrary`), but also `.app`/`.bundle`/etc. Pass the
    /// `.isPackageKey` resource value if you already fetched it (avoids a second stat); the extension
    /// list is a fallback for filesystems/enumerators that don't populate that key. Used by BOTH the
    /// file scanner and the Folders-tree directory walk so the two stay in sync (skipping in one place
    /// but not the other is how the Photos-library internals leaked into the Folders view).
    func isOpaqueMediaPackage(isPackage: Bool?) -> Bool {
        if isPackage == true { return true }
        return ["photoslibrary", "migratedphotolibrary", "aplibrary", "photolibrary"]
            .contains(pathExtension.lowercased())
    }
}
