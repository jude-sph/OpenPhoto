import SwiftUI
import OpenPhotoCore

struct ImportItemCell: View {
    let item: ImportItem
    let source: any ImportSource
    let alreadyImported: Bool
    let importedThisSession: Bool
    let selected: Bool
    let onToggle: () -> Void
    @State private var thumb: CGImage?

    // Mirrors the timeline's PhotoCellView: media is clipped to the rounded
    // cell shape, then every decorative overlay (selection ring, checkbox,
    // badges) is layered ON TOP of the clip so it can never be cut off — the
    // grid's outer rectangular .clipped() only ever trims the media edges.
    var body: some View {
        media
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.cellRadius)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) { checkbox.padding(6) }
            .overlay(alignment: .topTrailing) { kindBadge }
            .overlay(alignment: .bottom) { statusBadge }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .task(id: item.id) { thumb = await source.thumbnail(item, maxPixel: 360) }
    }

    private var media: some View {
        ZStack {
            Theme.tile
            if let thumb {
                Image(decorative: thumb, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if selected { Theme.accent.opacity(0.18) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var checkbox: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white, selected ? Theme.accent : Color.black.opacity(0.45))
            .shadow(radius: 2)
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
