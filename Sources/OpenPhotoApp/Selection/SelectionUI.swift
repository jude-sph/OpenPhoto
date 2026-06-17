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
    /// Publish this cell's frame in `space` for rubber-band selection — only while
    /// `active` (select mode). When browsing, the per-cell GeometryReader (hundreds
    /// of them, plus the preference aggregation) is gone entirely; the outer
    /// `.background` stays so the cell keeps its identity (no thumbnail re-decode).
    func cellFrame(_ id: String, in space: String, active: Bool = true) -> some View {
        background {
            if active {
                GeometryReader { geo in
                    Color.clear.preference(key: CellFramesKey.self,
                                           value: [id: geo.frame(in: .named(space))])
                }
            }
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
    @State private var dragRect: CGRect?             // visual marquee, viewport space
    // Auto-scroll while the pointer is dragged near the top/bottom edge.
    @State private var scrollPos = ScrollPosition(edge: .top)
    @State private var viewportH: CGFloat = 0
    @State private var contentOffsetY: CGFloat = 0
    @State private var maxOffsetY: CGFloat = 0
    @State private var edgeDir: CGFloat = 0          // -1 up, +1 down, 0 none
    // Drag anchor + current pointer. The anchor is stored in CONTENT coordinates (viewport +
    // scroll offset) so the selection rect spans from the drag start to the pointer no matter how
    // far the view auto-scrolls; a viewport-fixed rect would deselect rows that scroll above it.
    @State private var dragging = false
    @State private var anchorContentY: CGFloat = 0
    @State private var anchorX: CGFloat = 0
    @State private var pointerViewport: CGPoint = .zero

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
                if !dragging {
                    dragging = true
                    selection.beginDrag(subtracting: NSEvent.modifierFlags.contains(.shift))
                    anchorContentY = v.startLocation.y + contentOffsetY   // anchor in content space
                    anchorX = v.startLocation.x
                }
                pointerViewport = v.location
                applySelection()
                // Near an edge → start/keep auto-scrolling in that direction.
                let y = v.location.y
                edgeDir = y < edgeZone ? -1
                        : (viewportH > 0 && y > viewportH - edgeZone ? 1 : 0)
            }
            .onEnded { _ in
                guard enabled else { return }
                selection.endDrag(); dragRect = nil; edgeDir = 0; dragging = false
            }
    }

    /// Recompute the selection (and the visual marquee) from the content-space anchor and the
    /// current pointer at the live scroll offset. Working in content coordinates means a row that
    /// scrolls above the viewport during auto-scroll stays inside the rect instead of reverting.
    private func applySelection() {
        let offset = contentOffsetY
        let curContentY = pointerViewport.y + offset
        let top = min(anchorContentY, curContentY), bottom = max(anchorContentY, curContentY)
        let left = min(anchorX, pointerViewport.x), right = max(anchorX, pointerViewport.x)
        let contentRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        // Cell frames arrive in the (viewport-relative) named space; lift them into content space.
        var contentFrames: [String: CGRect] = [:]
        contentFrames.reserveCapacity(cellFrames.count)
        for (id, f) in cellFrames {
            contentFrames[id] = CGRect(x: f.minX, y: f.minY + offset, width: f.width, height: f.height)
        }
        selection.updateDrag(rect: contentRect, frames: contentFrames, items: items)
        // Visual marquee in viewport space, CLAMPED to the viewport — once the anchor scrolls off the
        // top, `top - offset` goes negative and the (unclipped) overlay would otherwise paint up over
        // the toolbar. Selection still uses the full content rect above; only the drawing is clamped.
        let vh = viewportH > 0 ? viewportH : .greatestFiniteMagnitude
        let vTop = max(0, top - offset)
        let vBottom = min(vh, bottom - offset)
        dragRect = CGRect(x: left, y: vTop, width: right - left, height: max(0, vBottom - vTop))
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
            applySelection()   // content-anchored: extends the rect as the view scrolls
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
    var moveControls: AnyView? = nil    // Folders screen injects its move cluster here
    var sendTargetName: String? = nil       // non-nil → show "Send to <name>"
    var onSend: () -> Void = {}
    let onDelete: () -> Void
    let onEvict: () -> Void
    var onForceEvict: () -> Void = {}
    var showRehydrate: Bool = false
    var onRehydrate: () -> Void = {}
    var tagControls: AnyView? = nil     // "Tag person…" menu (Timeline + Folders inject it)
    var shareControls: AnyView? = nil   // native ShareLink (Timeline + Folders inject it)
    let onDeselect: () -> Void
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            if let moveControls { moveControls }
            if let tagControls, count > 0 { tagControls }
            Button("Deselect", action: onDeselect).disabled(count == 0).controlSize(.small)
            if let shareControls, count > 0 { shareControls }
            if let name = sendTargetName {
                Button(action: onSend) {
                    Label("Send to \(name)", systemImage: "paperplane")
                }.disabled(count == 0).controlSize(.small)
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(count == 0).controlSize(.small)
            .help("Move to the bin and queue removal from drives (review before it propagates).")
            Button(action: onEvict) {
                Label("Evict…", systemImage: "arrow.down.circle")
            }
            .disabled(count == 0).controlSize(.small)
            .help("Free local space — keep the copy on the drive. Doesn’t delete anywhere.")
            if showRehydrate {
                Button(action: onRehydrate) {
                    Label("Rehydrate", systemImage: "arrow.down.circle.dotted")
                }.disabled(count == 0).controlSize(.small)
                    .help("Copy the selected drive-only originals back to this Mac.")
            }
            Menu {
                Button(role: .destructive, action: onForceEvict) {
                    Label("Force Evict (skip verification)…", systemImage: "exclamationmark.triangle")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(count == 0)
            Button("Done", action: onDone).controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}

/// The deliberate, ack-gated confirmation for Force Evict (skip verification).
struct ForceEvictSheet: View {
    let count: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Force Evict \(count) photo\(count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
            Text("This releases the local originals without re-checking the drive. If the drive copy is missing or damaged, these originals will be lost when you empty the Trash.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Toggle("I understand these originals may be unrecoverable.", isOn: $acknowledged)
                .font(.system(size: 12)).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Force Evict") { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!acknowledged)
            }
        }
        .padding(20).frame(width: 420)
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
