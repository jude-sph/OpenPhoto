import SwiftUI
import OpenPhotoCore

/// Collects each cell's frame (in a named grid coordinate space) for rubber-band hit-testing.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this cell's frame in `space` for rubber-band selection.
    func cellFrame(_ id: String, in space: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: CellFramesKey.self,
                                   value: [id: geo.frame(in: .named(space))])
        })
    }

    /// Selection ring + checkbox, shown only while `show` (select mode) is true.
    @ViewBuilder
    func selectionChrome(selected: Bool, show: Bool,
                         radius: CGFloat = Theme.cellRadius) -> some View {
        if show {
            self
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Theme.accent : .black.opacity(0.45))
                        .shadow(radius: 2).padding(7)
                }
        } else {
            self
        }
    }
}

/// Rubber-band drag selection over a grid. Apply to the scrolling container; the
/// container must declare `.coordinateSpace(name: space)` and its cells must use
/// `.cellFrame(id, in: space)`. Coexists with two-finger scroll (separate input).
struct RubberBandModifier: ViewModifier {
    @Binding var selection: SelectionModel
    let items: [SelectableItem]
    let space: String
    let enabled: Bool
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragRect: CGRect?
    // Auto-scroll while the pointer is dragged near the top/bottom edge.
    @State private var scrollPos = ScrollPosition(edge: .top)
    @State private var viewportH: CGFloat = 0
    @State private var contentOffsetY: CGFloat = 0
    @State private var maxOffsetY: CGFloat = 0
    @State private var edgeDir: CGFloat = 0          // -1 up, +1 down, 0 none
    @State private var lastRect: CGRect = .zero

    private struct ScrollMetrics: Equatable { var offset: CGFloat; var maxOffset: CGFloat }
    private let edgeZone: CGFloat = 48

    func body(content: Content) -> some View {
        content
            .overlay { overlayRect }
            .onPreferenceChange(CellFramesKey.self) { frames in
                Task { @MainActor in cellFrames = frames }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportH = $0 }
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: ScrollMetrics.self) {
                ScrollMetrics(offset: $0.contentOffset.y,
                              maxOffset: max(0, $0.contentSize.height - $0.containerSize.height))
            } action: { _, m in
                contentOffsetY = m.offset; maxOffsetY = m.maxOffset
            }
            .simultaneousGesture(dragGesture)
            .task(id: edgeDir) { await autoScroll() }
    }

    @ViewBuilder private var overlayRect: some View {
        if let r = dragRect {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(space))
            .onChanged { v in
                guard enabled else { return }
                if dragRect == nil { selection.beginDrag() }
                let rect = CGRect(x: min(v.startLocation.x, v.location.x),
                                  y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x),
                                  height: abs(v.location.y - v.startLocation.y))
                dragRect = rect
                lastRect = rect
                selection.updateDrag(rect: rect, frames: cellFrames, items: items)
                // Near an edge → start/keep auto-scrolling in that direction.
                let y = v.location.y
                edgeDir = y < edgeZone ? -1
                        : (viewportH > 0 && y > viewportH - edgeZone ? 1 : 0)
            }
            .onEnded { _ in
                guard enabled else { return }
                selection.endDrag(); dragRect = nil; edgeDir = 0
            }
    }

    /// While held near an edge, scroll that way (animations off, for smoothness)
    /// and keep extending the selection to cells entering the viewport-fixed rect.
    private func autoScroll() async {
        guard enabled, edgeDir != 0 else { return }
        var target = contentOffsetY
        while !Task.isCancelled && edgeDir != 0 {
            target = min(maxOffsetY, max(0, target + 22 * edgeDir))
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { scrollPos.scrollTo(y: target) }
            selection.updateDrag(rect: lastRect, frames: cellFrames, items: items)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// Two-finger pinch on a grid changes the cell-size slider value (zoom in/out),
/// clamped to the slider's range. Apply as a simultaneous gesture so it coexists
/// with scroll, tap, and rubber-band selection.
struct PinchZoomGridModifier: ViewModifier {
    @Binding var gridMinSize: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var base: CGFloat?
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.01)
                .onChanged { value in
                    let b = base ?? gridMinSize
                    if base == nil { base = b }
                    gridMinSize = min(range.upperBound, max(range.lowerBound, b * value.magnification))
                }
                .onEnded { _ in base = nil }
        )
    }
}

extension View {
    func pinchZoomGrid(_ gridMinSize: Binding<CGFloat>,
                       in range: ClosedRange<CGFloat> = 48...220) -> some View {
        modifier(PinchZoomGridModifier(gridMinSize: gridMinSize, range: range))
    }
}

/// The toolbar shown while a grid is in select mode.
struct SelectionActionBar: View {
    let count: Int
    var sendTargetName: String? = nil       // non-nil → show "Send to <name>"
    var onSend: () -> Void = {}
    let onEvict: () -> Void
    let onDeselect: () -> Void
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Deselect", action: onDeselect).disabled(count == 0).controlSize(.small)
            if let name = sendTargetName {
                Button(action: onSend) {
                    Label("Send to \(name)", systemImage: "paperplane")
                }.disabled(count == 0).controlSize(.small)
            }
            Button(role: .destructive, action: onEvict) {
                Label("Evict…", systemImage: "trash")
            }
            .disabled(count == 0).controlSize(.small)
            Button("Done", action: onDone).controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}

/// Body text for the evict confirmation, elevated when only-copies are present.
func evictAlertMessage(total: Int, onlyCopy: Int) -> String {
    if onlyCopy > 0 {
        return "\(onlyCopy) of these appear to exist only on this Mac — OpenPhoto "
             + "has no record of them anywhere else. Everything moves to the "
             + "recoverable bin, but those aren't backed up elsewhere."
    }
    return "They'll move to the bin and can be restored anytime."
}
