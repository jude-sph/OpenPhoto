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

    public static func createFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        try FileManager.default.createDirectory(at: vault.absoluteURL(forRelativePath: p),
                                                withIntermediateDirectories: true)
    }

    public static func deleteEmptyFolder(in vault: Vault, relPath: String) throws {
        let p = norm(relPath); guard !p.isEmpty else { throw ReorgError.invalidTarget }
        let url = vault.absoluteURL(forRelativePath: p)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if contents.contains(where: { $0 != ".openphoto" && !$0.hasPrefix(".") }) {
            throw ReorgError.notEmpty
        }
        try? FileManager.default.removeItem(at: url.appendingPathComponent(".openphoto"))
        try FileManager.default.removeItem(at: url)
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
}
