import Foundation

public struct CatalogIngest: Sendable {
    let catalog: Catalog
    let thumbnails: ThumbnailStore
    public init(catalog: Catalog, thumbnails: ThumbnailStore) {
        self.catalog = catalog; self.thumbnails = thumbnails
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
