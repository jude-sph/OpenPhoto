import Foundation
import GRDB

/// A drive carries a disposable copy of the Mac's machine-derived catalog + thumbnails under
/// `.openphoto/catalog-snapshot/`, so a fresh Mac can browse instantly. Never a source of truth;
/// regenerated wholesale; the drive's manifest is authoritative. See docs/format §7.
public enum CatalogSnapshot {
    static let dirName = "catalog-snapshot"

    /// Drive-relative path of a hash's thumbnail inside the snapshot (mirrors ThumbnailStore layout).
    static func thumbRelPath(forHash hash: String) -> String {
        let hex = String(hash.split(separator: ":").last ?? "x")
        return "thumbs/\(hex.prefix(2))/\(hex).jpg"
    }

    /// Write the snapshot atomically: VACUUM the live catalog into a clean copy, copy thumbnails for
    /// the drive's manifest hashes, write snapshot.json, then swap the temp dir over the old one.
    public static func write(catalog: Catalog, thumbnails: ThumbnailStore, drive: Vault) throws {
        let fm = FileManager.default
        let hashes = try Manifest.read(from: drive.manifestURL).map { $0.hash.stringValue }

        let tmp = drive.stateDirURL.appendingPathComponent("\(dirName).tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // VACUUM INTO a clean single-file copy (runs OUTSIDE a transaction).
        let dbDest = tmp.appendingPathComponent("catalog.sqlite")
        let escaped = dbDest.path.replacingOccurrences(of: "'", with: "''")
        try catalog.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }

        // Thumbnails — only the drive's hashes.
        for h in hashes {
            let src = thumbnails.cacheURL(for: ContentHash(stringValue: h))
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = tmp.appendingPathComponent(thumbRelPath(forHash: h))
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }

        // Header.
        let meta: [String: Any] = [
            "format_version": 1, "catalog_schema_version": 4,
            "source_vault_id": drive.descriptor.vaultID,
            "written_at": ISO8601Millis.string(from: Date()),
            "asset_count": hashes.count]
        try AtomicFile.write(try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .prettyPrinted]),
                             to: tmp.appendingPathComponent("snapshot.json"))

        // Atomic swap.
        let final = drive.stateDirURL.appendingPathComponent(dirName)
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: final)
        }
    }
}
