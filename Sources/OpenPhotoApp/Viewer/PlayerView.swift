import SwiftUI
import AVKit

/// Hosts AppKit's `AVPlayerView` (native controls + two-finger-scroll scrub) inside a clipping
/// container, and adds trackpad **pinch-to-zoom** + **drag-to-pan** on top. SwiftUI's `VideoPlayer`
/// crashes in this command-line/SPM-built bundle, and `AVPlayerView` has no zoom API — so we scale
/// the player within a masked container. The gestures are chosen so nothing collides:
/// - pinch (magnify) → zoom
/// - two-finger scroll → scrub (the player's own gesture, untouched)
/// - click without moving → play/pause (untouched)
/// - click-drag, only while zoomed → pan
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> ZoomablePlayerView { ZoomablePlayerView(player: player) }
    func updateNSView(_ v: ZoomablePlayerView, context: Context) { v.setPlayer(player) }
}

final class ZoomablePlayerView: NSView, NSGestureRecognizerDelegate {
    private let playerView = AVPlayerView()
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var panGesture: NSPanGestureRecognizer!

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        addSubview(playerView)
        playerView.addGestureRecognizer(
            NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        let pg = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pg.delegate = self
        playerView.addGestureRecognizer(pg)
        panGesture = pg
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Reset zoom/pan when the clip changes (a new AVPlayer is bound).
    func setPlayer(_ p: AVPlayer) {
        guard playerView.player !== p else { return }
        playerView.player = p
        zoom = 1; pan = .zero
        layoutPlayer()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutPlayer() }
    override func layout() { super.layout(); layoutPlayer() }

    @objc private func handlePinch(_ g: NSMagnificationGestureRecognizer) {
        zoom = min(max(1, zoom * (1 + g.magnification)), 6)
        g.magnification = 0   // accumulate incrementally
        if zoom == 1 { pan = .zero }
        layoutPlayer()
    }

    @objc private func handlePan(_ g: NSPanGestureRecognizer) {
        guard zoom > 1 else { return }
        let t = g.translation(in: self)
        pan.x += t.x; pan.y += t.y
        g.setTranslation(.zero, in: self)
        layoutPlayer()
    }

    /// Only let the pan gesture begin while zoomed — at 1x, a click must reach the player
    /// (play/pause) and scrolling must stay free for scrubbing.
    func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
        g === panGesture ? zoom > 1 : true
    }

    /// Scale the player to `zoom`x of the container (centered + panned, clamped to its edges); the
    /// container clips, so zooming shows part of the video. At 1x the player fills the container.
    private func layoutPlayer() {
        let w = bounds.width * zoom
        let h = bounds.height * zoom
        let maxX = max(0, (w - bounds.width) / 2)
        let maxY = max(0, (h - bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
        playerView.frame = CGRect(x: (bounds.width - w) / 2 + pan.x,
                                  y: (bounds.height - h) / 2 + pan.y,
                                  width: w, height: h)
    }
}
