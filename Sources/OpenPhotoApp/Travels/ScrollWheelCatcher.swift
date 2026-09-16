import SwiftUI
import AppKit

/// Transparent overlay that forwards trackpad/mouse scroll deltas (SwiftUI has no scroll-wheel
/// gesture on macOS). Sits over the ring stage; clicks pass through (`hitTest` returns nil).
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onScroll = onScroll; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }
    // The monitor is torn down here (and whenever the view leaves its window) rather than in a
    // `deinit`, which cannot touch the (non-Sendable) token under Swift 6 concurrency checking.
    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.stopMonitoring() }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // never swallow clicks/drags
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let win = self.window, e.window === win else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                // Precise (trackpad) deltas are in points; line-based (mouse wheel) are scaled up.
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8
                self.onScroll?(e.scrollingDeltaX * k, e.scrollingDeltaY * k)
                return nil                                               // consumed
            }
        }
        func stopMonitoring() { monitor.map(NSEvent.removeMonitor); monitor = nil }
        private var monitor: Any?
    }
}
