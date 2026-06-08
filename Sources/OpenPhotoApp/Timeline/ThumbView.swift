import SwiftUI
import OpenPhotoCore

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
        .clipped()
        .task(id: item.hash) {
            let lib = library, it = item
            image = await Task.detached(priority: .userInitiated) {
                guard let url = lib.absoluteURL(for: it) else { return nil }
                return try? await lib.thumbnails.thumbnail(
                    for: ContentHash(stringValue: it.hash), sourceURL: url,
                    kind: MediaKind(rawValue: it.kind) ?? .photo)
            }.value
        }
    }
}
