import SwiftUI
import OpenPhotoCore

/// Thread-safe wrapper so CGImage (CF type) can be stored in NSCache<NSString, AnyObject>.
private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

nonisolated(unsafe) private let thumbMemoryCache: NSCache<NSString, CGImageBox> = {
    let c = NSCache<NSString, CGImageBox>()
    c.countLimit = 6000   // dense continuous-mode grids keep many tiny cells alive
    return c
}()

struct ThumbView: View {
    let item: TimelineItem
    let library: LibraryService
    /// Target texture size in pixels — sized to the cell so tiny cells don't carry
    /// 512px textures (the cause of the Space-switch compositing hitch at min zoom).
    var targetPixel: Int = ThumbnailStore.maxPixel
    @State private var asyncImage: CGImage?

    // Cache (and reuse) one decoded image per (asset, texture-size) bucket.
    private var cacheKey: NSString { "\(item.hash)@\(targetPixel)" as NSString }

    var body: some View {
        // Read the memory cache SYNCHRONOUSLY so a recycled cell shows its cached
        // image on the very first render — no nil→tile→async flash. On a zoom-bucket
        // change for the SAME cell, `asyncImage` (the prior bucket) bridges the gap
        // so there's still no flash, just a one-frame size change.
        let cached = thumbMemoryCache.object(forKey: cacheKey)?.image ?? asyncImage
        ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: cacheKey) {
            let key = cacheKey
            if let hit = thumbMemoryCache.object(forKey: key)?.image { asyncImage = hit; return }
            let lib = library, it = item, px = targetPixel
            let result = await Task.detached(priority: .userInitiated) {
                guard let url = lib.absoluteURL(for: it) else { return CGImage?.none }
                return try? await lib.thumbnails.displayImage(
                    for: ContentHash(stringValue: it.hash), sourceURL: url,
                    kind: MediaKind(rawValue: it.kind) ?? .photo, maxPixel: px)
            }.value
            if let img = result {
                thumbMemoryCache.setObject(CGImageBox(img), forKey: key)
                asyncImage = img
            }
        }
    }
}
