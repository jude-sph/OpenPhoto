import SwiftUI
import OpenPhotoCore

/// Thread-safe box so CGImage (a CF type) can live in NSCache<NSString, AnyObject>.
final class TileImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// One shared decoded-thumbnail cache for every grid/strip in the app.
nonisolated(unsafe) let tileMemoryCache: NSCache<NSString, TileImageBox> = {
    let c = NSCache<NSString, TileImageBox>()
    c.countLimit = 6000   // dense continuous-mode grids keep many tiny cells alive
    return c
}()

/// The app's single async-thumbnail view. Reads the shared memory cache SYNCHRONOUSLY so a
/// recycled cell shows instantly (no nil->tile->async flash), then refreshes off a detached task.
/// Source-agnostic: the caller supplies a `@Sendable` provider, so timeline, folders, import, and
/// quick view share this one loader + cache.
struct ThumbnailImage: View {
    let id: String
    let provider: @Sendable (_ maxPixel: Int) async -> CGImage?
    var targetPixel: Int = ThumbnailStore.maxPixel
    @State private var asyncImage: CGImage?

    private var cacheKey: NSString { "\(id)@\(targetPixel)" as NSString }

    var body: some View {
        let cached = tileMemoryCache.object(forKey: cacheKey)?.image ?? asyncImage
        ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: cacheKey) {
            let key = cacheKey
            if let hit = tileMemoryCache.object(forKey: key)?.image { asyncImage = hit; return }
            let load = provider, px = targetPixel
            let result = await Task.detached(priority: .userInitiated) { await load(px) }.value
            if let img = result {
                tileMemoryCache.setObject(TileImageBox(img), forKey: key)
                asyncImage = img
            }
        }
    }
}

extension ThumbnailImage {
    /// Convenience for catalog-backed items (timeline, folders, viewer, send): thumbnail from the
    /// library's store (cache hit by hash, else generate from the resolved file), falling back to
    /// the cached image. Identity keyed by `instanceID`.
    init(timelineItem item: TimelineItem, library: LibraryService,
         targetPixel: Int = ThumbnailStore.maxPixel) {
        let lib = library
        let hash = ContentHash(stringValue: item.hash)
        let kind = MediaKind(rawValue: item.kind) ?? .photo
        let it = item
        self.init(id: item.instanceID, provider: { px in
            if let url = lib.absoluteURL(for: it),
               let img = try? await lib.thumbnails.displayImage(
                   for: hash, sourceURL: url, kind: kind, maxPixel: px) {
                return img
            }
            return await lib.thumbnails.cachedDisplayImage(for: hash, maxPixel: px)
        }, targetPixel: targetPixel)
    }
}

/// Texture size to render a grid cell at, for a given grid min-cell size. (Moved verbatim from the
/// deleted PhotoCellView.swift.) Sized for the worst case (adaptive cells grow up to ~2x the min) at
/// retina (~2x), bucketed to multiples of 64 so the slider doesn't re-decode every tick, capped at
/// the stored thumbnail size.
func gridThumbnailPixels(forCellMin minSize: CGFloat) -> Int {
    let needed = Int(minSize * 4)
    let bucket = ((needed + 63) / 64) * 64
    return min(ThumbnailStore.maxPixel, max(128, bucket))
}
