import SwiftUI
import AppKit

/// Repositions the window's traffic-light buttons into a vertical column when `vertical` is true
/// (so they fit OpenPhoto's narrow 38px collapsed sidebar strip), and restores the standard
/// horizontal layout otherwise. AppKit re-lays-out the buttons on window resize, so we re-apply
/// on `didResize`. Layout is expressed as offsets from the window-frame top, so it survives resizes.
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
        /// The system's horizontal layout, captured once as (x, distance-from-top) per button.
        private var horizontal: (x: [NSWindow.ButtonType: CGFloat], topGap: [NSWindow.ButtonType: CGFloat])?
        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        init(vertical: Bool) { self.vertical = vertical }

        func attach(_ v: NSView) { view = v; scheduleReposition() }

        func scheduleReposition() {
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        private func reposition() {
            guard let window = view?.window else { scheduleReposition(); return }   // window not ready yet
            guard let close = window.standardWindowButton(.closeButton),
                  let frame = close.superview else { return }
            if token == nil {
                token = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                }
            }
            let h = frame.bounds.height   // button superview = window frame view (origin bottom-left)
            // Capture the system's horizontal layout once, before we ever move the buttons.
            if horizontal == nil {
                var x: [NSWindow.ButtonType: CGFloat] = [:]
                var gap: [NSWindow.ButtonType: CGFloat] = [:]
                for t in Self.types {
                    if let b = window.standardWindowButton(t) { x[t] = b.frame.minX; gap[t] = h - b.frame.minY }
                }
                horizontal = (x, gap)
            }
            guard let base = horizontal else { return }
            let bh = close.frame.height
            if vertical {
                let cx = max(0, (38 - close.frame.width) / 2)        // centered in the 38px strip
                let topGap = base.topGap[.closeButton] ?? 6
                let step = bh + 6                                     // button + gap
                for (i, t) in Self.types.enumerated() {
                    window.standardWindowButton(t)?
                        .setFrameOrigin(NSPoint(x: cx, y: h - topGap - CGFloat(i) * step))
                }
            } else {
                for t in Self.types {
                    window.standardWindowButton(t)?
                        .setFrameOrigin(NSPoint(x: base.x[t] ?? 0, y: h - (base.topGap[t] ?? 6)))
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
