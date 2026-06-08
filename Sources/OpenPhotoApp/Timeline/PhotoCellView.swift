import SwiftUI
import OpenPhotoCore

struct PhotoCellView: View {
    let item: TimelineItem
    let library: LibraryService
    var targetPixel: Int = ThumbnailStore.maxPixel
    var onDelete: () -> Void = {}

    var body: some View {
        // No per-cell hover effect: at high density (tiny cells in continuous mode)
        // hundreds of .onHover tracking areas make scrolling lag. Apple Photos
        // doesn't hover-scale either.
        ThumbView(item: item, library: library, targetPixel: targetPixel)
            .overlay(alignment: .topTrailing) {
                if item.livePairHash != nil {
                    badge(symbol: "livephoto")
                } else if item.kind == MediaKind.video.rawValue {
                    badge(symbol: "play.fill", text: duration)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 2).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .contentShape(Rectangle())
            // No per-cell .contextMenu: SwiftUI builds menu infrastructure per cell,
            // which makes dense LazyVGrid scrolling janky. Delete is available in the
            // viewer (open a photo → Delete key).
    }

    private var duration: String? {
        guard let s = item.durationSeconds else { return nil }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func badge(symbol: String, text: String? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if let text { Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(5)
    }
}

/// Texture size to render a grid cell at, for a given grid min-cell size. Sized for
/// the worst case (adaptive cells grow up to ~2× the min) at retina (~2×), bucketed
/// to multiples of 64 so the slider doesn't re-decode every tick, and capped at the
/// stored thumbnail size. Small zoom → small textures → no Space-switch hitch.
func gridThumbnailPixels(forCellMin minSize: CGFloat) -> Int {
    let needed = Int(minSize * 4)              // ~2× adaptive growth × ~2× retina
    let bucket = ((needed + 63) / 64) * 64     // round up to a 64px bucket
    return min(ThumbnailStore.maxPixel, max(128, bucket))
}
