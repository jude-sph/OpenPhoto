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
            "format_version": 1, "catalog_schema_version": Catalog.schemaVersion,
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

public struct AdoptionImport: Sendable, Equatable {
    public var assets: Int      // assets read from the snapshot
    public var present: Int     // this-drive presence rows seeded
    public init(assets: Int, present: Int) { self.assets = assets; self.present = present }
}

extension CatalogSnapshot {
    /// Seed the live catalog from a drive's snapshot for instant drive-only browse. Reads ONLY the
    /// portable parts (assets + this drive's vault_presence) from a READ-ONLY open of the snapshot DB
    /// (never writes to the drive). Assets are inserted-if-absent (never clobber local metadata).
    public static func `import`(from drive: Vault, into catalog: Catalog,
                                thumbnails: ThumbnailStore) throws -> AdoptionImport {
        let snapDir = drive.stateDirURL.appendingPathComponent(dirName)
        let dbURL = snapDir.appendingPathComponent("catalog.sqlite")
        var cfg = Configuration(); cfg.readonly = true
        let snap = try DatabaseQueue(path: dbURL.path, configuration: cfg)

        let assets = try snap.read { db in try AssetRecord.fetchAll(db) }
        let presence: [VaultPresenceEntry] = try snap.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, relPath, dirPath, size, driveRelPath FROM vault_presence WHERE vaultID = ?
                """, arguments: [drive.descriptor.vaultID]).map {
                VaultPresenceEntry(hash: $0["hash"], relPath: $0["relPath"], dirPath: $0["dirPath"],
                                   size: $0["size"], driveRelPath: $0["driveRelPath"])
            }
        }

        try catalog.insertAssetsIfAbsent(assets)
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: presence)

        let fm = FileManager.default
        let thumbsDir = snapDir.appendingPathComponent("thumbs")
        if let en = fm.enumerator(at: thumbsDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "jpg" {
                let stem = u.deletingPathExtension().lastPathComponent
                let dst = thumbnails.cacheURL(for: ContentHash(stringValue: "sha256:" + stem))
                guard !fm.fileExists(atPath: dst.path) else { continue }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: u, to: dst)
            }
        }
        return AdoptionImport(assets: assets.count, present: presence.count)
    }
}

extension CatalogSnapshot {
    /// hash → takenAtMs from a drive's snapshot — the read-only fast path that lets a
    /// foreign drive's 10k items date-sort without touching 10k files. Reads ONLY the
    /// portable `assets` table per the documented snapshot-reader rules (catalog-schema.md);
    /// returns nil when the drive has no (readable) snapshot — callers fall back to
    /// manifest mtimes.
    public static func assetDates(drive: Vault) -> [String: Int64]? {
        let dbURL = drive.stateDirURL.appendingPathComponent(dirName)
            .appendingPathComponent("catalog.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var cfg = Configuration(); cfg.readonly = true
        guard let snap = try? DatabaseQueue(path: dbURL.path, configuration: cfg) else { return nil }
        return try? snap.read { db in
            var out: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT hash, takenAtMs FROM assets") {
                out[row["hash"]] = row["takenAtMs"]
            }
            return out
        }
    }
}

extension CatalogSnapshot {
    /// Reconcile an adopted drive's presence against its authoritative manifest (the snapshot may be
    /// stale). No re-hash, no file reads beyond the manifest: drop presence whose hash isn't in the
    /// manifest; add presence (and a minimal asset) for every manifest hash that's missing.
    public static func verifyAdoption(drive: Vault, into catalog: Catalog,
                                      sourceBasenames: [String]) throws {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let manifestHashes = Set(manifest.map { $0.hash.stringValue })
        let current = try catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)
        let currentByHash = Dictionary(current.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })

        var merged: [VaultPresenceEntry] = current.filter { manifestHashes.contains($0.hash) }
        var minimalAssets: [AssetRecord] = []
        for e in manifest where currentByHash[e.hash.stringValue] == nil {
            let hash = e.hash.stringValue
            let mac = DrivePathMap.driveToMacRelPath(e.path, sourceBasenames: sourceBasenames)
            merged.append(VaultPresenceEntry(hash: hash, relPath: mac,
                dirPath: (mac as NSString).deletingLastPathComponent, size: e.size, driveRelPath: e.path))
            let kind = MediaKind.of(filename: e.path)?.rawValue ?? MediaKind.photo.rawValue
            let takenMs = ISO8601Millis.dateLenient(from: e.mtime).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            minimalAssets.append(AssetRecord(hash: hash, kind: kind, takenAtMs: takenMs,
                pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
                lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
        }
        try catalog.insertAssetsIfAbsent(minimalAssets)
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: merged)
    }
}
