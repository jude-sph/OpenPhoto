import Foundation
import CryptoKit

/// One peekable photo/video, backend-agnostic (snapshot drive OR raw folder).
public struct PeekItem: Sendable, Identifiable, Equatable {
    public var id: String          // stable identity (the source file path / drive-relative path)
    public var name: String        // filename, for display
    public var kind: MediaKind
    public var sourceURL: URL      // the file on the drive/folder — thumbnail source AND full-res
    public var thumbHash: ContentHash  // real asset hash (snapshot) or a path-derived synthetic (raw)

    public init(id: String, name: String, kind: MediaKind, sourceURL: URL, thumbHash: ContentHash) {
        self.id = id; self.name = name; self.kind = kind
        self.sourceURL = sourceURL; self.thumbHash = thumbHash
    }
}

/// A loaded, ephemeral peek: the items + a THROWAWAY thumbnail cache, all under `tempDir`.
public struct PeekContext: Sendable {
    public var sourceName: String              // drive/folder display name (the banner)
    public var items: [PeekItem]
    public var thumbnails: ThumbnailStore      // temp cache (cacheDir under tempDir)
    public var tempDir: URL                    // deleted wholesale on teardown
    public var root: URL                       // the peeked drive/folder (for eject-mid-peek detection)

    public init(sourceName: String, items: [PeekItem], thumbnails: ThumbnailStore,
                tempDir: URL, root: URL) {
        self.sourceName = sourceName; self.items = items
        self.thumbnails = thumbnails; self.tempDir = tempDir; self.root = root
    }
}

/// The two read-only backends behind one loader.
public enum PeekSource {
    /// Build a peek for `root` into a fresh `tempDir`. If `root` carries a catalog-snapshot it's read
    /// instantly (snapshot backend); otherwise its media files are enumerated (raw backend). Reads
    /// only — never writes to `root`.
    public static func load(root: URL, tempDir: URL) throws -> PeekContext {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let thumbs = ThumbnailStore(cacheDir: tempDir.appendingPathComponent("thumbs"))

        let snapshotDB = root.appendingPathComponent(Vault.stateDirName)
            .appendingPathComponent("catalog-snapshot")
            .appendingPathComponent("catalog.sqlite")

        if fm.fileExists(atPath: snapshotDB.path) {
            // SNAPSHOT backend. Open the drive READ-ONLY via Vault.open so we NEVER write to a
            // passive drive. If vault.json has vanished despite the snapshot DB, fall through to the
            // raw backend (still a valid peek) rather than creating a vault.json on the drive.
            guard let drive = try Vault.open(at: root) else {
                return loadRaw(root: root, tempDir: tempDir, thumbs: thumbs)
            }
            let cat = try Catalog(at: tempDir.appendingPathComponent("catalog.sqlite"))
            _ = try CatalogSnapshot.import(from: drive, into: cat, thumbnails: thumbs)
            let items = try cat.timelineItems()
                .filter { $0.driveRelPath != nil }
                .map { row in
                    PeekItem(id: row.driveRelPath!,
                             name: (row.relPath as NSString).lastPathComponent,
                             kind: MediaKind(rawValue: row.kind) ?? .photo,
                             sourceURL: drive.absoluteURL(forRelativePath: row.driveRelPath!),
                             thumbHash: ContentHash(stringValue: row.hash))
                }
            return PeekContext(sourceName: root.lastPathComponent, items: items,
                               thumbnails: thumbs, tempDir: tempDir, root: root)
        }

        return loadRaw(root: root, tempDir: tempDir, thumbs: thumbs)
    }

    /// RAW backend — read-only media walk; NEVER openOrCreate a raw folder.
    private static func loadRaw(root: URL, tempDir: URL, thumbs: ThumbnailStore) -> PeekContext {
        let items = mediaFiles(under: root).map { url in
            PeekItem(id: url.path,
                     name: url.lastPathComponent,
                     kind: MediaKind.of(filename: url.lastPathComponent) ?? .photo,
                     sourceURL: url,
                     thumbHash: syntheticHash(forPath: url.path))
        }
        return PeekContext(sourceName: root.lastPathComponent, items: items,
                           thumbnails: thumbs, tempDir: tempDir, root: root)
    }

    /// Recursive, read-only walk of media files under `root` (skips `.openphoto/`, hidden files, and
    /// non-media). Sorted by path for a stable order.
    public static func mediaFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.lastPathComponent == Vault.stateDirName { en.skipDescendants(); continue }
            if MediaKind.of(filename: url.lastPathComponent) != nil { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A path-derived `ContentHash` (SHA-256 of the path STRING, not the file bytes — instant, stable,
    /// filename-safe) used to key a raw item's throwaway thumbnail cache.
    public static func syntheticHash(forPath path: String) -> ContentHash {
        let digest = SHA256.hash(data: Data(path.utf8))
        return ContentHash(stringValue: "sha256:" + digest.map { String(format: "%02x", $0) }.joined())
    }
}
