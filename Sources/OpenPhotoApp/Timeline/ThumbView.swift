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
    @State private var asyncImage: CGImage?

    var body: some View {
        // Read the memory cache SYNCHRONOUSLY so a recycled cell shows its cached
        // image on the very first render — no nil→tile→async flash and no extra
        // render pass per cell, which is what made dense scrolling janky.
        let cached = asyncImage ?? thumbMemoryCache.object(forKey: item.hash as NSString)?.image
        ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: item.hash) {
            let key = item.hash as NSString
            if thumbMemoryCache.object(forKey: key) != nil { return }   // already cached
            let lib = library, it = item
            let result = await Task.detached(priority: .userInitiated) {
                guard let url = lib.absoluteURL(for: it) else { return CGImage?.none }
                return try? await lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: it.hash), sourceURL: url,
                    kind: MediaKind(rawValue: it.kind) ?? .photo)
            }.value
            if let img = result {
                thumbMemoryCache.setObject(CGImageBox(img), forKey: key)
                asyncImage = img
            }
        }
    }
}
