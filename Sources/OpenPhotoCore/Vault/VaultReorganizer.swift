import Foundation

/// Real on-disk folder moves/creates/deletes within a vault, with manifest path rewrites.
/// Same-volume FileManager.moveItem is an atomic rename; the moved subtree carries its
/// per-dir `.openphoto/` sidecars for free. The catalog is rebuilt by a rescan afterwards.
public enum VaultReorganizer {
    public enum ReorgError: Error { case invalidTarget, destinationExists, notEmpty, missing }

    @discardableResult
    public static func moveFolder(in vault: Vault, relPath: String,
                                  intoParentRelPath parent: String) throws -> String {
        let src = norm(relPath)
        let dstParent = norm(parent)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        if dstParent == src || dstParent.hasPrefix(src + "/") { throw ReorgError.invalidTarget }
        let name = (src as NSString).lastPathComponent
        let newPath = dstParent.isEmpty ? name : dstParent + "/" + name
        if newPath == src { return src }
        try assertContained(src, in: vault); try assertContained(newPath, in: vault)
        let fm = FileManager.default
        let srcURL = vault.absoluteURL(forRelativePath: src)
        let dstURL = vault.absoluteURL(forRelativePath: newPath)
        guard fm.fileExists(atPath: srcURL.path) else { throw ReorgError.missing }
        if fm.fileExists(atPath: dstURL.path) { throw ReorgError.destinationExists }
        try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: srcURL, to: dstURL)
        try rewriteManifest(vault, from: src, to: newPath)
        return newPath
    }

    /// Rename a folder in place (same parent, new last component). Same-volume atomic rename; the
    /// subtree carries its `.openphoto/` sidecars, and the manifest paths are rewritten. Returns the
    /// new relPath. Rejects an empty source (the library root), a name containing "/", or a collision.
    @discardableResult
    public static func renameFolder(in vault: Vault, relPath: String, toName newName: String) throws -> String {
        let src = norm(relPath)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw ReorgError.invalidTarget }
        let parent = (src as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? name : parent + "/" + name
        if newPath == src { return src }
        try assertContained(src, in: vault); try assertContained(newPath, in: vault)
        let fm = FileManager.default
        let srcURL = vault.absoluteURL(forRelativePath: src)
        let dstURL = vault.absoluteURL(forRelativePath: newPath)
        guard fm.fileExists(atPath: srcURL.path) else { throw ReorgError.missing }
        if fm.fileExists(atPath: dstURL.path) { throw ReorgError.destinationExists }
        try fm.moveItem(at: srcURL, to: dstURL)
        try rewriteManifest(vault, from: src, to: newPath)
        return newPath
    }

    public static func createFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        try assertContained(p, in: vault)
        try FileManager.default.createDirectory(at: vault.absoluteURL(forRelativePath: p),
                                                withIntermediateDirectories: true)
    }

    public static func deleteEmptyFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        try assertContained(p, in: vault)
        let url = vault.absoluteURL(forRelativePath: p)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if contents.contains(where: { $0 != ".openphoto" && !$0.hasPrefix(".") }) {
            throw ReorgError.notEmpty
        }
        try? FileManager.default.removeItem(at: url.appendingPathComponent(".openphoto"))
        try FileManager.default.removeItem(at: url)
    }

    /// Move ONE media file into another folder, collision-safe. The file's
    /// `.openphoto/<name>.xmp` sidecar travels with it (renamed to match any
    /// collision-adjusted basename) and its single manifest entry is rewritten.
    /// Finder-tag xattrs ride along (same-volume rename). Returns the final relPath.
    @discardableResult
    public static func moveFile(in vault: Vault, relPath: String,
                                intoDirRelPath dir: String) throws -> String {
        let src = norm(relPath)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        let name = (src as NSString).lastPathComponent
        let dstDir = norm(dir)
        return try moveFile(in: vault, relPath: src,
                            toRelPath: dstDir.isEmpty ? name : dstDir + "/" + name)
    }

    /// Exact-target variant — drive propagation reuses the Mac's final basename so
    /// Mac and drive paths stay aligned; collision-adjusts only if the target is
    /// occupied on THIS vault.
    @discardableResult
    public static func moveFile(in vault: Vault, relPath: String,
                                toRelPath target: String) throws -> String {
        let src = norm(relPath)
        var dst = norm(target)
        guard !src.isEmpty, !dst.isEmpty else { throw ReorgError.invalidTarget }
        if dst == src { return src }   // already there — no-op
        try assertContained(src, in: vault); try assertContained(dst, in: vault)
        let fm = FileManager.default
        let srcURL = vault.absoluteURL(forRelativePath: src)
        guard fm.fileExists(atPath: srcURL.path) else { throw ReorgError.missing }
        var dstURL = vault.absoluteURL(forRelativePath: dst)
        let dstDirURL = dstURL.deletingLastPathComponent()
        try fm.createDirectory(at: dstDirURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dstURL.path) {
            dstURL = FileNaming.collisionFreeURL(for: dstURL.lastPathComponent, in: dstDirURL)
            dst = vault.relativePath(of: dstURL)
        }
        try fm.moveItem(at: srcURL, to: dstURL)
        // Sidecar travels with the media, renamed to match the final basename.
        let srcSidecar = vault.sidecarURL(forMediaAt: srcURL)
        if fm.fileExists(atPath: srcSidecar.path) {
            let dstSidecar = vault.sidecarURL(forMediaAt: dstURL)
            try fm.createDirectory(at: dstSidecar.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try? fm.removeItem(at: dstSidecar)   // stale sidecar with no media — garbage
            try fm.moveItem(at: srcSidecar, to: dstSidecar)
        }
        try rewriteManifestEntry(vault, from: src, to: dst)
        return dst
    }

    private static func rewriteManifestEntry(_ vault: Vault, from old: String, to new: String) throws {
        let entries = try Manifest.read(from: vault.manifestURL)
        guard entries.contains(where: { $0.path == old }) else { return }  // not cataloged yet — rescan adopts it
        try Manifest.write(entries.map { e in
            e.path == old ? ManifestEntry(hash: e.hash, path: new, size: e.size, mtime: e.mtime) : e
        }, to: vault.manifestURL)
    }

    private static func rewriteManifest(_ vault: Vault, from oldDir: String, to newDir: String) throws {
        let entries = try Manifest.read(from: vault.manifestURL)
        let prefix = oldDir + "/"
        let updated = entries.map { e -> ManifestEntry in
            guard e.path == oldDir || e.path.hasPrefix(prefix) else { return e }
            let rest = String(e.path.dropFirst(oldDir.count))
            return ManifestEntry(hash: e.hash, path: newDir + rest, size: e.size, mtime: e.mtime)
        }
        try Manifest.write(updated, to: vault.manifestURL)
    }

    private static func norm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Reject any user-influenced path that contains a `.`/`..`/empty component, or that resolves
    /// outside the vault root — defence-in-depth against path-traversal from UI-typed folder names
    /// (e.g. renaming a folder to ".." or moving into "../../somewhere"). Call on the target (and
    /// source) relPath before any filesystem mutation. Hard invariant: nothing escapes the vault.
    static func assertContained(_ relPath: String, in vault: Vault) throws {
        for c in relPath.split(separator: "/", omittingEmptySubsequences: false) {
            if c.isEmpty || c == "." || c == ".." { throw ReorgError.invalidTarget }
        }
        let root = vault.rootURL.standardizedFileURL.path
        let resolved = vault.absoluteURL(forRelativePath: relPath).standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw ReorgError.invalidTarget }
    }
}
