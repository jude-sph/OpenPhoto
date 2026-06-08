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
        // Self-squaring: a clear 1:1 spacer drives the cell size; the real content
        // is an overlay filling that square. Only the MEDIA is clipped (rounded
        // corners). The checkbox / badges / selection ring are stacked on top and
        // are NEVER clipped — there must be no outer .clipped() around this cell,
        // or the corner checkbox gets cut off.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .topLeading) {
                    media
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if selected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.accent.opacity(0.18))
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                    }
                    checkbox.padding(8)
                }
                .overlay(alignment: .topTrailing) { kindBadge }
                .overlay(alignment: .bottom) { statusBadge }
            }
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
        }
    }

    private var checkbox: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Color.white : Color.white,
                             selected ? Theme.accent : Color.black.opacity(0.45))
            .background(Circle().fill(.black.opacity(0.3)).padding(3))
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
