import Foundation

public struct CatalogIngest: Sendable {
    let catalog: Catalog
    let thumbnails: ThumbnailStore
    public init(catalog: Catalog, thumbnails: ThumbnailStore) {
        self.catalog = catalog; self.thumbnails = thumbnails
    }

    /// Batch form of `ingestDriveFile`: catalog MANY drive files with ONE presence-table rewrite and
    /// ONE asset upsert (not one full-table rewrite per file, which made "Adopt all" crawl). Reads the
    /// known-hash set once. `progress(done, total)` fires per file (thumbnailing dominates the time).
    public func ingestDriveFiles(relPaths: [String], on drive: Vault, sourceBasenames: [String],
                                 progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        guard !relPaths.isEmpty else { return }
        let fm = FileManager.default
        var known = try catalog.knownHashes()                 // read ONCE (was per-file)
        var newAssets: [AssetRecord] = []
        var presenceByHash: [String: VaultPresenceEntry] = [:]
        let total = relPaths.count
        for (i, driveRelPath) in relPaths.enumerated() {
            progress(i + 1, total)
            let url = drive.absoluteURL(forRelativePath: driveRelPath)
            guard let kind = MediaKind.of(filename: url.lastPathComponent),
                  let hash = try? ContentHash.ofFile(at: url).stringValue else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
            if !known.contains(hash) {
                known.insert(hash)
                let m = await MetadataExtractor.extract(from: url, kind: kind)
                newAssets.append(AssetRecord(
                    hash: hash, kind: kind.rawValue, takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, latitude: m.latitude,
                    longitude: m.longitude, cameraModel: m.cameraModel, lensModel: m.lensModel,
                    durationSeconds: m.durationSeconds, livePairHash: nil, isLivePairedVideo: false,
                    favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
                _ = try? await thumbnails.thumbnail(for: ContentHash(stringValue: hash), sourceURL: url, kind: kind)
            }
            let mac = DrivePathMap.driveToMacRelPath(driveRelPath, sourceBasenames: sourceBasenames)
            presenceByHash[hash] = VaultPresenceEntry(hash: hash, relPath: mac,
                dirPath: (mac as NSString).deletingLastPathComponent, size: size, driveRelPath: driveRelPath)
        }
        if !newAssets.isEmpty { try catalog.upsert(assets: newAssets) }   // ONE upsert
        // ONE presence rewrite: keep existing rows for other hashes, add every new one.
        let newHashes = Set(presenceByHash.keys)
        let existing = try catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)
            .filter { !newHashes.contains($0.hash) }
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID,
                                         entries: existing + Array(presenceByHash.values))
    }

    /// Catalog a drive-resident file so it browses thumbnail-only: extract metadata, cache a
    /// thumbnail from the drive file, upsert the asset, and write the presence row.
    public func ingestDriveFile(relPath driveRelPath: String, on drive: Vault,
                                sourceBasenames: [String]) async throws {
        let url = drive.absoluteURL(forRelativePath: driveRelPath)
        guard let kind = MediaKind.of(filename: url.lastPathComponent) else { return }
        let hash = try ContentHash.ofFile(at: url).stringValue
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? 0

        // Only extract + thumbnail if the catalog doesn't already know this asset.
        if !(try catalog.knownHashes()).contains(hash) {
            let m = await MetadataExtractor.extract(from: url, kind: kind)
            try catalog.upsert(assets: [AssetRecord(
                hash: hash, kind: kind.rawValue, takenAtMs: Int64(m.takenAt.timeIntervalSince1970 * 1000),
                pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, latitude: m.latitude,
                longitude: m.longitude, cameraModel: m.cameraModel, lensModel: m.lensModel,
                durationSeconds: m.durationSeconds, livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
            _ = try? await thumbnails.thumbnail(for: ContentHash(stringValue: hash), sourceURL: url, kind: kind)
        }

        let mac = DrivePathMap.driveToMacRelPath(driveRelPath, sourceBasenames: sourceBasenames)
        let existing = try catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)
            .filter { $0.hash != hash }
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: existing + [
            VaultPresenceEntry(hash: hash, relPath: mac,
                               dirPath: (mac as NSString).deletingLastPathComponent,
                               size: size, driveRelPath: driveRelPath)])
    }
}

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
