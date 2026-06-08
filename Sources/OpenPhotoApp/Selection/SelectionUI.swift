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

    func body(content: Content) -> some View {
        content
            .overlay { overlayRect }
            .onPreferenceChange(CellFramesKey.self) { frames in
                Task { @MainActor in cellFrames = frames }
            }
            .simultaneousGesture(dragGesture)
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
                selection.updateDrag(rect: rect, frames: cellFrames, items: items)
            }
            .onEnded { _ in
                guard enabled else { return }
                selection.endDrag(); dragRect = nil
            }
    }
}

/// The toolbar shown while a grid is in select mode. (Send is added in Stage B.)
struct SelectionActionBar: View {
    let count: Int
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
