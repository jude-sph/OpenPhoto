import SwiftUI
import OpenPhotoCore

/// A selectable square import tile. The squaring + media clip happen on the
/// inner cell; the selection ring and checkbox are drawn on the OUTER
/// squared-and-clipped frame (after `.clipped()`), so they are pinned to the
/// visible cell corner and can never be clipped, regardless of how the inner
/// media sizes itself. Shared by the import grid and the free-up grid.
struct ImportTile: View {
    let item: ImportItem
    let source: any ImportSource
    let alreadyImported: Bool
    let importedThisSession: Bool
    var sentFromHere: Bool = false
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ImportItemCell(item: item, source: source,
                               alreadyImported: alreadyImported,
                               importedThisSession: importedThisSession,
                               sentFromHere: sentFromHere,
                               selected: selected)
            }
            // Round the whole visible tile to the SAME radius as the ring, so the
            // image corners sit exactly under the rounded ring (no square poke-out).
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.cellRadius)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Theme.accent : .black.opacity(0.45))
                    .shadow(radius: 2)
                    .padding(7)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
    }
}

/// Presentational cell: photo (+ selection tint) clipped to the cell shape, plus
/// the live/video and status badges. No selection chrome — `ImportTile` adds that.
struct ImportItemCell: View {
    let item: ImportItem
    let source: any ImportSource
    let alreadyImported: Bool
    let importedThisSession: Bool
    var sentFromHere: Bool = false
    let selected: Bool
    @State private var thumb: CGImage?

    var body: some View {
        ZStack {
            Theme.tile
            if let thumb {
                Image(decorative: thumb, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if selected { Theme.accent.opacity(0.18) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()   // ImportTile rounds the final tile; here we just pin/clip the fill
        .overlay(alignment: .topTrailing) { kindBadge }
        .overlay(alignment: .bottom) { statusBadge }
        .task(id: item.id) { thumb = await source.thumbnail(item, maxPixel: 360) }
    }

    @ViewBuilder private var kindBadge: some View {
        if item.livePartnerID != nil, item.kind == .photo {
            Image(systemName: "livephoto").font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white).padding(5)
                .background(.black.opacity(0.45), in: Capsule()).padding(6)
        } else if item.kind == .video {
            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white).padding(5)
                .background(.black.opacity(0.45), in: Capsule()).padding(6)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if importedThisSession {
            badge("Imported ✓", color: Theme.green)
        } else if sentFromHere {
            badge("Sent from here", color: Theme.blue)
        } else if alreadyImported {
            badge("Already in library", color: Theme.textFaint)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(color).padding(6)
    }
}
