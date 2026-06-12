import Foundation
import ImageIO
import CoreGraphics

/// Read-only ImportSource over SOMEONE ELSE's OpenPhoto vault (a friend's canonical or
/// backup drive). Enumerates from the drive's documented formats — manifest.jsonl for the
/// inventory, the catalog snapshot (when present) for capture dates + thumbnails — so a
/// 10k-item drive lists without touching 10k files. Never writes to the drive (drives are
/// passive; this one isn't even ours).
public final class ForeignVaultSource: ImportSource, @unchecked Sendable {
    public let sourceKey: String
    public let displayName: String
    private let vault: Vault
    private let lock = NSLock()
    private var cachedEntries: [ManifestEntry]?
    private var cachedDates: [String: Int64]?    // hash → takenAtMs (snapshot fast path)

    public init(vault: Vault, displayName: String) {
        self.vault = vault
        self.displayName = displayName
        self.sourceKey = "foreign-" + vault.descriptor.vaultID
    }

    private func entries() throws -> [ManifestEntry] {
        lock.lock(); defer { lock.unlock() }
        if let cachedEntries { return cachedEntries }
        let e = try Manifest.read(from: vault.manifestURL)
        cachedEntries = e
        return e
    }

    private func snapshotDates() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        if let cachedDates { return cachedDates }
        let d = CatalogSnapshot.assetDates(drive: vault) ?? [:]
        cachedDates = d
        return d
    }

    /// dirPath → direct media count, from the manifest alone (drives the folder panel).
    public func folderCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in try entries() where MediaKind.of(filename: e.path) != nil {
            counts[(e.path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        return counts
    }

    public func enumerateItems() async throws -> [ImportItem] {
        let dates = snapshotDates()
        var items: [ImportItem] = []
        for e in try entries() {
            guard let kind = MediaKind.of(filename: e.path) else { continue }
            let hash = e.hash.stringValue
            let taken: Date? = if let ms = dates[hash], ms != 0 {
                Date(timeIntervalSince1970: Double(ms) / 1000)
            } else {
                ISO8601Millis.dateLenient(from: e.mtime)
            }
            items.append(ImportItem(id: e.path, name: (e.path as NSString).lastPathComponent,
                                    byteSize: e.size, takenAt: taken, kind: kind,
                                    livePartnerID: nil, knownHash: hash))
        }
        items.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        return pairLiveItems(items)
    }

    public func fetch(_ item: ImportItem, to url: URL) async throws {
        try FileManager.default.copyItem(at: vault.absoluteURL(forRelativePath: item.id), to: url)
    }

    public func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { DeleteResult(itemID: $0.id, error: "someone else's drive — read-only") }
    }

    /// Their `.openphoto/<name>.xmp` sidecar bytes for an item (metadata-carry toggle).
    public func sidecarData(for item: ImportItem) -> Data? {
        try? Data(contentsOf: vault.sidecarURL(forMediaAt: vault.absoluteURL(forRelativePath: item.id)))
    }

    public func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? {
        // Snapshot thumbnail first — no full-res decode off the drive.
        if let hash = item.knownHash {
            let thumbURL = vault.stateDirURL.appendingPathComponent(CatalogSnapshot.dirName)
                .appendingPathComponent(CatalogSnapshot.thumbRelPath(forHash: hash))
            if let src = CGImageSourceCreateWithURL(thumbURL as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
        }
        let url = vault.absoluteURL(forRelativePath: item.id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
