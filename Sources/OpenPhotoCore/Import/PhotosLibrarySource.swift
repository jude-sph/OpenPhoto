import Foundation
import CoreGraphics
import AppKit
@preconcurrency import Photos

/// ImportSource for the Mac's Apple Photos library (which is also the iCloud
/// library — network-allowed requests pull iCloud-only originals down on demand).
/// Read-only: copies originals out, never writes to Photos. Hardware-tested, not
/// unit-tested (PHAsset can't be constructed off a real library) — keep this thin.
public final class PhotosLibrarySource: ImportSource, @unchecked Sendable {
    public let sourceKey = "photoslib"
    public let displayName = "Apple Photos"

    enum Role: String { case original, edited, video }
    private struct Entry { let asset: PHAsset; let resource: PHAssetResource; let favorite: Bool; let kind: MediaKind }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]   // ImportItem.id → fetch instruction

    public init() {}

    /// Request read access. `.authorized`/`.limited` can enumerate.
    public static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
    }

    public static var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: opts)

        var items: [ImportItem] = []
        var map: [String: Entry] = [:]

        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let id = asset.localIdentifier
            let created = asset.creationDate
            let fav = asset.isFavorite

            func size(_ r: PHAssetResource) -> Int64 { (r.value(forKey: "fileSize") as? Int64) ?? 0 }
            func emit(_ role: Role, _ res: PHAssetResource, name: String, kind: MediaKind,
                      partnerID: String?) {
                let itemID = "photoslib:\(id):\(role.rawValue)"
                map[itemID] = Entry(asset: asset, resource: res, favorite: fav, kind: kind)
                items.append(ImportItem(id: itemID, name: name, byteSize: size(res),
                                        takenAt: created, kind: kind, livePartnerID: partnerID))
            }

            if asset.mediaType == .image {
                guard let photo = resources.first(where: { $0.type == .photo })
                        ?? resources.first(where: { $0.type == .fullSizePhoto }) else { return }
                let base = photo.originalFilename
                let stillID = "photoslib:\(id):original"
                let paired = resources.first { $0.type == .pairedVideo }
                let videoID = paired != nil ? "photoslib:\(id):video" : nil
                emit(.original, photo, name: base, kind: .photo, partnerID: videoID)
                if let edited = resources.first(where: { $0.type == .fullSizePhoto }) {
                    emit(.edited, edited, name: Self.editedName(base), kind: .photo, partnerID: nil)
                }
                if let paired {
                    emit(.video, paired, name: (base as NSString).deletingPathExtension + ".mov",
                         kind: .video, partnerID: stillID)
                }
            } else if asset.mediaType == .video {
                guard let video = resources.first(where: { $0.type == .video }) else { return }
                emit(.original, video, name: video.originalFilename, kind: .video, partnerID: nil)
                if let edited = resources.first(where: { $0.type == .fullSizeVideo }) {
                    emit(.edited, edited, name: Self.editedName(video.originalFilename), kind: .video, partnerID: nil)
                }
            }
        }
        lock.withLock { entries = map }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        guard let entry = lock.withLock({ entries[item.id] }) else { throw CocoaError(.fileNoSuchFile) }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: entry.resource, toFile: url, options: opts) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        if entry.favorite, item.kind == .photo {
            try? EmbeddedMetadata.embed(
                SidecarData(rating: 0, favorite: true, caption: nil, tags: [], faces: []),
                exifDate: nil, latitude: nil, longitude: nil, intoImageAt: url)
        }
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "Apple Photos import is read-only") }
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        guard let entry = lock.withLock({ entries[item.id] }) else { return nil }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        let size = CGSize(width: maxPixel, height: maxPixel)
        return await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
            let box = ResumeOnce(c)
            PHImageManager.default().requestImage(for: entry.asset, targetSize: size,
                                                  contentMode: .aspectFill, options: opts) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                box.resume(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private static func editedName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) (edited)" : "\(base) (edited).\(ext)"
    }

    /// PHImageManager.opportunistic can fire its completion more than once; resume the
    /// continuation exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        private let c: CheckedContinuation<CGImage?, Never>
        init(_ c: CheckedContinuation<CGImage?, Never>) { self.c = c }
        func resume(_ v: CGImage?) {
            let go = lock.withLock { if done { return false }; done = true; return true }
            if go { c.resume(returning: v) }
        }
    }
}
