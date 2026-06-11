import SwiftUI
import AppKit

/// Repositions the window's traffic-light buttons into a vertical column when `vertical` is true
/// (so they fit OpenPhoto's narrow 38px collapsed sidebar strip), and restores the standard
/// horizontal layout otherwise.
///
/// The buttons normally live in the short title-bar container, which clips hit-testing to its own
/// bounds — so a button moved below it is drawn but unclickable. We reparent the three buttons into
/// the window's full-height frame view (`contentView.superview`), where they're hit-testable wherever
/// we place them and sit above the content. Layout is expressed as offsets from the frame-view top,
/// so it survives window resizes; we re-apply on `didResize`.
struct VerticalTrafficLights: NSViewRepresentable {
    var vertical: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.vertical = vertical
        context.coordinator.scheduleReposition()
    }
    func makeCoordinator() -> Coordinator { Coordinator(vertical: vertical) }

    @MainActor
    final class Coordinator {
        var vertical: Bool
        private weak var view: NSView?
        private nonisolated(unsafe) var token: NSObjectProtocol?
        /// The system's horizontal layout, captured once as (x, distance-from-top) per button,
        /// in frame-view coordinates, before we reparent anything.
        private var layout: [(x: CGFloat, topGap: CGFloat)]?
        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        init(vertical: Bool) { self.vertical = vertical }

        func attach(_ v: NSView) { view = v; scheduleReposition() }

        func scheduleReposition() {
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        private func reposition() {
            guard let window = view?.window else { scheduleReposition(); return }   // window not ready yet
            let buttons = Self.types.compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let themeFrame = window.contentView?.superview else { return }
            if token == nil {
                token = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                }
            }
            let H = themeFrame.bounds.height
            // Capture the system's horizontal layout once, in frame-view coords, BEFORE reparenting.
            if layout == nil {
                layout = buttons.map { b in
                    let p = (b.superview ?? themeFrame).convert(b.frame.origin, to: themeFrame)
                    return (x: p.x, topGap: H - p.y)
                }
            }
            guard let base = layout else { return }
            // Reparent into the full-height frame view so the buttons are hit-testable wherever we
            // move them (the title-bar container clips hit-testing to its short height) and sit on top.
            for b in buttons where b.superview !== themeFrame { themeFrame.addSubview(b) }
            if vertical {
                let cx = max(0, (38 - buttons[0].frame.width) / 2)   // centered in the 38px strip
                let topGap = base[0].topGap
                let step = buttons[0].frame.height + 6               // button + gap
                for (i, b) in buttons.enumerated() {
                    b.setFrameOrigin(NSPoint(x: cx, y: H - topGap - CGFloat(i) * step))
                }
            } else {
                for (i, b) in buttons.enumerated() {
                    b.setFrameOrigin(NSPoint(x: base[i].x, y: H - base[i].topGap))
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
