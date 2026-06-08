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

    var body: some View {
        ZStack {
            Theme.tile
            if let thumb {
                Image(decorative: thumb, scale: 1).resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))   // clip the MEDIA only
        .overlay {                                        // selection ring + tint (never clipped away)
            if selected {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .background(Theme.accent.opacity(0.18).clipShape(RoundedRectangle(cornerRadius: 10)))
            }
        }
        .overlay(alignment: .topLeading) {                // ALWAYS show checkbox (imported too)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.95),
                                 selected ? Theme.accent : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.25)).padding(2))
                .shadow(radius: 2)
                .padding(8)
        }
        .overlay(alignment: .topTrailing) {
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
        .overlay(alignment: .bottom) {
            if importedThisSession {
                badge("Imported ✓", color: Theme.green)
            } else if alreadyImported {
                badge("Already in library", color: Theme.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }                      // selectable regardless of imported state
        .task(id: item.id) {
            thumb = await source.thumbnail(item, maxPixel: 360)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(color).padding(6)
    }
}
