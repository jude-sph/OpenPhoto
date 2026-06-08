import SwiftUI
import OpenPhotoCore

struct PhotoCellView: View {
    let item: TimelineItem
    let library: LibraryService
    var onDelete: () -> Void = {}

    var body: some View {
        // No per-cell hover effect: at high density (tiny cells in continuous mode)
        // hundreds of .onHover tracking areas make scrolling lag. Apple Photos
        // doesn't hover-scale either.
        ThumbView(item: item, library: library)
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
