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
    // The count alone bounds nothing: 6000 × a 512 px bitmap (~1 MB) is ~6 GB. Bound the BYTES;
    // every insert passes its decoded size (see `cacheTileImage`).
    c.totalCostLimit = 600 * 1024 * 1024
    return c
}()

/// Insert into the shared tile cache with the bitmap's decoded size as its cost.
func cacheTileImage(_ image: CGImage, forKey key: NSString) {
    tileMemoryCache.setObject(TileImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
}

/// The app's single async-thumbnail view. Reads the shared memory cache SYNCHRONOUSLY so a
/// recycled cell shows instantly (no nil->tile->async flash), then refreshes off a detached task.
/// Source-agnostic: the caller supplies a `@Sendable` provider, so timeline, folders, import, and
/// quick view share this one loader + cache.
struct ThumbnailImage: View {
    let id: String
    let provider: @Sendable (_ maxPixel: Int) async -> CGImage?
    var targetPixel: Int = ThumbnailStore.maxPixel
    var rotation: Int = 0   // display rotation (0/90/180/270 CW); applied as a render transform
    /// false when the caller already clips this view to its own frame (a `MediaTile` does), so the
    /// tile isn't clipped twice.
    var clips: Bool = true
    @State private var asyncImage: CGImage?
    /// The `id` that `asyncImage` was loaded for. An image is only ever drawn under its own id.
    @State private var asyncImageID: String?

    private var cacheKey: NSString { "\(id)@\(targetPixel)" as NSString }

    var body: some View {
        // This view may have been REUSED for a different item (recycled map pin / grid cell): never
        // render the previous item's image under this id — that was the "same photo on 3 map pins"
        // bug. The same item at another pixel size is fine to keep showing (see the task below).
        let cached = tileMemoryCache.object(forKey: cacheKey)?.image
            ?? (asyncImageID == id ? asyncImage : nil)
        let tile = ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .rotationEffect(.degrees(Double(rotation)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Group {
            if clips { tile.clipped() } else { tile }
        }
        .task(id: cacheKey) {
            let key = cacheKey, loadingID = id
            if let hit = tileMemoryCache.object(forKey: key)?.image {
                asyncImage = hit; asyncImageID = loadingID; return
            }
            // Cache miss. A different ITEM → drop the old image and show the placeholder until the
            // right one loads. The SAME item at a new pixel size (zooming across a size bucket re-keys
            // every realised tile at once) → keep showing what we have until the new size arrives,
            // instead of blanking the whole grid.
            if asyncImageID != loadingID { asyncImage = nil; asyncImageID = nil }
            let load = provider, px = targetPixel
            let result = await Task.detached(priority: .userInitiated) { await load(px) }.value
            // Ignore a result that arrived after another reuse already changed our id.
            if let img = result, key == cacheKey {
                cacheTileImage(img, forKey: key)
                asyncImage = img; asyncImageID = loadingID
            }
        }
    }
}

extension ThumbnailImage {
    /// Convenience for catalog-backed items (timeline, folders, viewer, send): thumbnail from the
    /// library's store (cache hit by hash, else generate from the resolved file), falling back to
    /// the cached image. Identity keyed by `instanceID`.
    init(timelineItem item: TimelineItem, library: LibraryService,
         targetPixel: Int = ThumbnailStore.maxPixel, clips: Bool = true) {
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
        }, targetPixel: targetPixel, rotation: item.rotation, clips: clips)
    }
}

/// Texture size to render a grid cell at, for a given grid min-cell size. Sized for the worst case
/// (adaptive cells grow up to ~2x the min) at retina (~2x), in three coarse buckets — 128 / 256 /
/// 512 — capped at the stored thumbnail size. Coarse on purpose: crossing a bucket re-decodes every
/// realised tile, and the old multiples-of-64 buckets put six of those boundaries inside the zoom
/// slider's 48…220 range; this leaves one (at a 64 pt cell).
func gridThumbnailPixels(forCellMin minSize: CGFloat) -> Int {
    let needed = Int(minSize * 4)
    let bucket = needed <= 128 ? 128 : (needed <= 256 ? 256 : 512)
    return min(ThumbnailStore.maxPixel, bucket)
}

/// How much chrome a grid cell draws at a given grid min-cell size. Two coarse flags rather than the
/// raw size, so it can sit in `MediaGridCell`'s `==` without re-rendering every tile on each zoom tick.
struct GridCellDensity: Equatable {
    /// Small cells skip the rounded-corner clip (3 pt corners are invisible at that size; a plain
    /// rectangle clip is cheaper across thousands of tiles).
    let squareCorners: Bool
    /// Small cells hide the kind / presence / favourite badges — too small to read there.
    let showBadges: Bool

    static let regular = GridCellDensity(squareCorners: false, showBadges: true)

    init(squareCorners: Bool, showBadges: Bool) {
        self.squareCorners = squareCorners; self.showBadges = showBadges
    }
    init(cellMin: CGFloat) {
        self.init(squareCorners: cellMin < 64, showBadges: cellMin >= 56)
    }
}
