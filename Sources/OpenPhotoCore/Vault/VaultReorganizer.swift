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
        let dst = norm(target)
        guard !src.isEmpty, !dst.isEmpty else { throw ReorgError.invalidTarget }
        if dst == src { return src }   // already there — no-op
        let final = try relocateFileAndSidecar(in: vault, fromSrc: src, toDst: dst)
        try rewriteManifestEntries(vault, mapping: [src: final])
        return final
    }

    /// Batch exact-target move (drive propagation): relocate each `from → to` file + sidecar on
    /// `vault`, collision-safe, then rewrite the manifest ONCE for the whole batch. Best-effort
    /// per file (a file that can't move is skipped, the batch continues). Returns `from → final`
    /// (collision-adjusted) for the files that moved — so an N-file drive move costs one drive
    /// manifest rewrite, not N.
    @discardableResult
    public static func moveFilesExact(in vault: Vault,
                                      moves: [(from: String, to: String)]) throws -> [String: String] {
        var mapping: [String: String] = [:]
        for m in moves {
            let from = norm(m.from), to = norm(m.to)
            guard !from.isEmpty, !to.isEmpty, from != to else { continue }
            if let final = try? relocateFileAndSidecar(in: vault, fromSrc: from, toDst: to) {
                mapping[from] = final
            }
        }
        try rewriteManifestEntries(vault, mapping: mapping)
        return mapping
    }

    /// Batch helper for `movePhotos`: relocate a file's bytes + sidecar (collision-safe) WITHOUT
    /// rewriting the manifest, returning the final relPath. The caller collects every `old → final`
    /// and rewrites the manifest ONCE for the whole batch (`rewriteManifestEntries`) — so an N-file
    /// move pays one manifest read+write, not N. Mirrors the `intoDirRelPath:` move signature.
    static func moveFileNoManifest(in vault: Vault, relPath: String,
                                   intoDirRelPath dir: String) throws -> String {
        let src = norm(relPath)
        guard !src.isEmpty else { throw ReorgError.invalidTarget }
        let name = (src as NSString).lastPathComponent
        let dstDir = norm(dir)
        let dst = dstDir.isEmpty ? name : dstDir + "/" + name
        if dst == src { return src }   // already there — no-op
        return try relocateFileAndSidecar(in: vault, fromSrc: src, toDst: dst)
    }

    /// Move ONE file's bytes + its `.openphoto/*.xmp` sidecar, collision-safe, returning the final
    /// relPath. Same-volume atomic rename; Finder-tag xattrs ride along. Does NOT touch the manifest
    /// — every caller (`moveFile`, `moveFileNoManifest`) decides how to record the path change.
    private static func relocateFileAndSidecar(in vault: Vault, fromSrc src: String,
                                               toDst dst0: String) throws -> String {
        var dst = dst0
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
        return dst
    }

    /// Apply a batch of `old → new` path rewrites to the vault manifest in a SINGLE read + write —
    /// the primitive that makes an N-file move cost one manifest rewrite, not N. Entries whose path
    /// isn't in `mapping` are left exactly as-is; a mapping whose `old` isn't present is ignored (the
    /// file isn't cataloged yet — a rescan adopts it). Hash/size/mtime are preserved verbatim.
    public static func rewriteManifestEntries(_ vault: Vault, mapping: [String: String]) throws {
        guard !mapping.isEmpty else { return }
        let entries = try Manifest.read(from: vault.manifestURL)
        guard entries.contains(where: { mapping[$0.path] != nil }) else { return }  // nothing here to rewrite
        try Manifest.write(entries.map { e in
            guard let new = mapping[e.path] else { return e }
            return ManifestEntry(hash: e.hash, path: new, size: e.size, mtime: e.mtime)
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
