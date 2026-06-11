import SwiftUI
import AppKit

/// Invisible view that reports mouse enter/exit over its frame without intercepting clicks.
/// Used to drive the traffic-light rollover when the buttons are stacked vertically (the system's
/// own rollover tracking area stays at the buttons' original horizontal spot).
final class HoverColumnView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // pass clicks through to the buttons
}

/// Repositions the window's traffic-light buttons into a vertical column when `vertical` is true
/// (so they fit OpenPhoto's narrow 38px collapsed sidebar strip), and restores the standard
/// horizontal layout otherwise. Handles the three AppKit gotchas of moving the real buttons:
///   1. Hit-testing is clipped to a parent's bounds — so in windowed mode we reparent the buttons
///      into the window's full-height frame view, where they're clickable wherever we place them.
///   2. Full screen relocates the buttons into the menu-bar overlay — so we hand them back to their
///      original parent on the fullscreen transition and re-apply on exit.
///   3. The rollover (×/−/+ on hover) is driven by a system tracking area that doesn't follow the
///      moved buttons — so we lay our own tracking area over the column and drive the rollover.
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
        private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        private var originalParents: [NSView] = []
        private var layout: [(x: CGFloat, topGap: CGFloat)]?
        private var captured = false
        private var inFullScreen = false
        private var hoverView: HoverColumnView?

        init(vertical: Bool) { self.vertical = vertical }

        func attach(_ v: NSView) { view = v; scheduleReposition() }

        func scheduleReposition() {
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        private func installObservers(_ window: NSWindow) {
            guard tokens.isEmpty else { return }
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window,
                queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
            tokens.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.inFullScreen = true; self?.restoreToSystem() } })
            tokens.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.inFullScreen = false; self?.reposition() } })
        }

        private func capture(_ frameView: NSView, _ buttons: [NSButton]) {
            guard !captured else { return }
            originalParents = buttons.map { $0.superview ?? frameView }
            let H = frameView.bounds.height
            layout = buttons.map { b in
                let p = (b.superview ?? frameView).convert(b.frame.origin, to: frameView)
                return (x: p.x, topGap: H - p.y)
            }
            captured = true
        }

        /// Hand the buttons back to the system (full screen → menu-bar overlay).
        private func restoreToSystem() {
            hoverView?.isHidden = true
            guard captured, let window = view?.window else { return }
            let buttons = Self.types.compactMap { window.standardWindowButton($0) }
            for (i, b) in buttons.enumerated() where i < originalParents.count {
                if b.superview !== originalParents[i] { originalParents[i].addSubview(b) }
            }
        }

        /// Drive the window buttons' group-rollover state (private, guarded so it can never crash).
        private func setRollover(_ on: Bool, _ buttons: [NSButton]) {
            let sel = Selector(("_setMouseInGroup:"))
            typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
            for b in buttons where b.responds(to: sel) {
                if let imp = b.method(for: sel) { unsafeBitCast(imp, to: Fn.self)(b, sel, on) }
            }
        }

        private func reposition() {
            guard let window = view?.window else { scheduleReposition(); return }   // window not ready yet
            let buttons = Self.types.compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let frameView = window.contentView?.superview else { return }
            installObservers(window)
            capture(frameView, buttons)
            // In full screen, the system owns the buttons (menu-bar overlay) — don't fight it.
            if inFullScreen || window.styleMask.contains(.fullScreen) { restoreToSystem(); return }
            guard let base = layout else { return }
            let H = frameView.bounds.height
            // Reparent into the full-height frame view so the buttons are hit-testable wherever we
            // move them (the title-bar container clips hit-testing to its short height) and sit on top.
            for b in buttons where b.superview !== frameView { frameView.addSubview(b) }
            let bh = buttons[0].frame.height
            if vertical {
                let cx = max(0, (38 - buttons[0].frame.width) / 2)   // centered in the 38px strip
                let step = bh + 6                                    // button + gap
                let topY = H - base[0].topGap
                for (i, b) in buttons.enumerated() {
                    b.setFrameOrigin(NSPoint(x: cx, y: topY - CGFloat(i) * step))
                }
                // Our own rollover tracking over the column.
                let hv = hoverView ?? {
                    let v = HoverColumnView(); frameView.addSubview(v); hoverView = v; return v
                }()
                hv.isHidden = false
                hv.frame = NSRect(x: 0, y: topY - 2 * step - 4, width: 40, height: 2 * step + bh + 8)
                hv.onHover = { [weak self] inside in self?.setRollover(inside, buttons) }
            } else {
                hoverView?.isHidden = true
                for (i, b) in buttons.enumerated() {
                    b.setFrameOrigin(NSPoint(x: base[i].x, y: H - base[i].topGap))
                }
            }
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
