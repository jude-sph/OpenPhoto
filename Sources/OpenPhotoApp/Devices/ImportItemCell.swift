import SwiftUI
import OpenPhotoCore

/// A selectable square import tile, built on the shared MediaTile.
struct ImportTile: View {
    let item: ImportItem
    let source: any ImportSource
    let alreadyImported: Bool
    let importedThisSession: Bool
    var sentFromHere: Bool = false
    /// The photo already exists ANYWHERE in OpenPhoto's catalog (any source, including drive-only) —
    /// matched by size + capture-second before download. Shown as a drive glyph.
    var inLibrary: Bool = false
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        let src = source, it = item
        MediaTile(
            id: item.id,
            selectMode: true,
            selected: selected,
            rubberBandSpace: nil,    // import grids don't rubber-band via MediaTile's hook
            thumbnail: ThumbnailImage(id: item.id, provider: { px in
                await src.thumbnail(it, maxPixel: px)
            }, targetPixel: 360),
            badges: { badges },
            onTap: onToggle)
    }

    @ViewBuilder private var badges: some View {
        ZStack {
            kindBadge.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            statusBadge.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            if inLibrary && !importedThisSession {
                badgeIcon("externaldrive.fill", size: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .help("Already in your OpenPhoto library")
            }
        }
    }

    @ViewBuilder private var kindBadge: some View {
        if item.livePartnerID != nil, item.kind == .photo {
            badgeIcon("livephoto", size: 11)
        } else if item.kind == .video {
            badgeIcon("play.fill", size: 10)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if importedThisSession { statusText("Imported \u{2713}", color: Theme.green) }
        else if sentFromHere { statusText("Sent from here", color: Theme.blue) }
        // The catalog-wide drive glyph supersedes the per-source "Already in library" text; show the
        // text only for the rare registry-knows-it-but-not-in-catalog case (e.g. since binned).
        else if alreadyImported && !inLibrary { statusText("Already in library", color: Theme.textFaint) }
    }

    private func badgeIcon(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: size, weight: .bold))
            .foregroundStyle(.white).padding(5)
            .background(.black.opacity(0.45), in: Capsule()).padding(6)
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(color).padding(6)
    }
}
