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
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.tile
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: item.hash) {
            let key = item.hash as NSString
            if let box = thumbMemoryCache.object(forKey: key) {
                image = box.image
                return
            }
            let lib = library, it = item
            let result = await Task.detached(priority: .userInitiated) {
                guard let url = lib.absoluteURL(for: it) else { return CGImage?.none }
                return try? await lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: it.hash), sourceURL: url,
                    kind: MediaKind(rawValue: it.kind) ?? .photo)
            }.value
            if let img = result {
                thumbMemoryCache.setObject(CGImageBox(img), forKey: key)
                image = img
            }
        }
    }
}
