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
        .clipped()
        .overlay(alignment: .topLeading) {
            if !alreadyImported {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.85))
                    .shadow(radius: 2).padding(8)
            }
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
        .opacity(alreadyImported && !importedThisSession ? 0.45 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if !alreadyImported { onToggle() } }
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
