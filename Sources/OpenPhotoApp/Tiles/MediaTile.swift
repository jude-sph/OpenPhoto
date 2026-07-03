import SwiftUI
import OpenPhotoCore

/// An `Equatable` wrapper around a timeline/folders `MediaTile`, so a whole-grid re-render (every
/// rubber-band tick re-evaluates the parent body) only re-runs the cells whose inputs ACTUALLY
/// changed — not every visible tile. Without this, dragging a marquee over a dense grid re-evaluates
/// hundreds of `MediaTile` bodies per frame; with it, only the handful crossing the marquee edge do.
///
/// The `==` keys on every value that affects rendering: `item` (Equatable — covers favorite/kind/
/// rotation/livePair/duration/driveRelPath/hash), `selected`, `selectMode`, `backedUp`, `thumbPixels`,
/// `space`. `onTap` is deliberately excluded: it reads `@State`/`@Bindable` storage (selection, items,
/// selectMode) which is reference-backed, so it always sees current values even when the body is
/// memoized — there is no stale-closure hazard.
struct MediaGridCell: View, Equatable {
    let id: String          // cell + rubber-band frame identity (folders: instanceID, timeline: hash)
    let item: TimelineItem
    let selectMode: Bool
    let selected: Bool
    let backedUp: Bool
    let thumbPixels: Int
    let space: String
    let library: LibraryService
    var onTap: () -> Void = {}

    nonisolated static func == (l: MediaGridCell, r: MediaGridCell) -> Bool {
        l.id == r.id && l.item == r.item && l.selectMode == r.selectMode && l.selected == r.selected
            && l.backedUp == r.backedUp && l.thumbPixels == r.thumbPixels && l.space == r.space
    }

    var body: some View {
        MediaTile(
            id: id,
            selectMode: selectMode,
            selected: selected,
            rubberBandSpace: space,
            thumbnail: ThumbnailImage(timelineItem: item, library: library, targetPixel: thumbPixels),
            badges: { TimelineTileBadges(item: item, backedUp: backedUp) },
            onTap: onTap)
    }
}

/// The one correct grid-cell chrome: a square frame, the thumbnail clipped to a rounded rect on the
/// OUTER frame, and the selection ring + checkbox + badges drawn on that SAME rounded frame -- so
/// corners never poke past the ring and badges are never clipped (the bug the timeline/folders cells
/// had). Adapted from the import grid's tile; used by timeline, folders, import, and quick view.
struct MediaTile<Thumb: View, Badges: View>: View {
    let id: String
    var selectMode: Bool = false
    var selected: Bool = false
    var rubberBandSpace: String? = nil
    let thumbnail: Thumb
    @ViewBuilder var badges: () -> Badges
    var onTap: () -> Void = {}

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { thumbnail }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellRadius))   // OUTER rounding
            .overlay { badges() }                                          // glyphs on the rounded frame
            .overlay {
                if selectMode && selected {
                    RoundedRectangle(cornerRadius: Theme.cellRadius)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                if selectMode {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Theme.accent : .black.opacity(0.45))
                        .shadow(radius: 2).padding(7)
                }
            }
            .modifier(CellFrameIfNeeded(id: id, space: rubberBandSpace, active: selectMode))
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}

/// Publishes the cell frame for rubber-band selection only when a space is set and select mode is on.
private struct CellFrameIfNeeded: ViewModifier {
    let id: String
    let space: String?
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if let space { content.cellFrame(id, in: space, active: active) } else { content }
    }
}

/// The timeline/folders badge set, each glyph inset within the rounded tile (drawn on the OUTER
/// rounded frame via MediaTile's `badges` overlay, so it renders consistently at every cell size).
struct TimelineTileBadges: View {
    let item: TimelineItem
    let backedUp: Bool

    var body: some View {
        ZStack {
            kindGlyph.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            presenceGlyph
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            if item.favorite {
                glyph("heart.fill", size: 10, color: .white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    @ViewBuilder private var kindGlyph: some View {
        if item.livePairHash != nil {
            capsule(symbol: "livephoto")
        } else if item.kind == MediaKind.video.rawValue {
            capsule(symbol: "play.fill", text: duration)
        }
    }

    private var duration: String? {
        guard let s = item.durationSeconds else { return nil }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// One presence badge, by priority — shown only when there's something to know.
    /// On-Mac + on-canonical (the safe, common case) shows nothing.
    @ViewBuilder private var presenceGlyph: some View {
        if item.driveRelPath != nil {
            if backedUp {
                glyph("externaldrive.fill", size: 10, color: .white.opacity(0.92))
                    .help("On the canonical drive \u{2014} connect it for full-res")
            } else {
                glyph("externaldrive.badge.exclamationmark", size: 10, color: Theme.amber)
                    .help("On a drive, not the canonical")
            }
        } else if !backedUp {
            glyph("exclamationmark.triangle.fill", size: 10, color: Theme.amber)
                .help("Not backed up to the canonical drive")
        }
    }

    private func glyph(_ symbol: String, size: CGFloat, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: size))
            .foregroundStyle(color).shadow(radius: 2).padding(6)
    }

    private func capsule(symbol: String, text: String? = nil) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if let text { Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
        }
        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule()).padding(6)
    }
}
