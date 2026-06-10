import SwiftUI
import AVKit

/// Hosts AppKit's `AVPlayerView` (native controls + two-finger-scroll scrub) inside a clipping
/// container, and adds trackpad **pinch-to-zoom** on top. SwiftUI's `VideoPlayer` crashes in this
/// command-line/SPM-built bundle, and `AVPlayerView` has no zoom API — so we scale the player
/// within a masked container on a magnify gesture, leaving the player's own scroll/click gestures
/// (scrubbing, play/pause) untouched. Pinch and two-finger-scroll are distinct gestures, so they
/// don't collide.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> ZoomablePlayerView { ZoomablePlayerView(player: player) }
    func updateNSView(_ v: ZoomablePlayerView, context: Context) { v.setPlayer(player) }
}

final class ZoomablePlayerView: NSView {
    private let playerView = AVPlayerView()
    private var zoom: CGFloat = 1

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        addSubview(playerView)
        // Pinch zooms; the AVPlayerView keeps its own two-finger-scroll scrub + click play/pause.
        playerView.addGestureRecognizer(
            NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Reset zoom when the clip changes (a new AVPlayer is bound).
    func setPlayer(_ p: AVPlayer) {
        guard playerView.player !== p else { return }
        playerView.player = p
        zoom = 1
        layoutPlayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayer()
    }
    override func layout() {
        super.layout()
        layoutPlayer()
    }

    @objc private func handlePinch(_ g: NSMagnificationGestureRecognizer) {
        zoom = min(max(1, zoom * (1 + g.magnification)), 6)
        g.magnification = 0   // accumulate incrementally
        layoutPlayer()
    }

    /// Scale the player to `zoom`x of the container, centered; the container clips, so zooming in
    /// shows the centre of the video. At 1x the player fills the container (normal playback).
    private func layoutPlayer() {
        let w = bounds.width * zoom
        let h = bounds.height * zoom
        playerView.frame = CGRect(x: (bounds.width - w) / 2,
                                  y: (bounds.height - h) / 2,
                                  width: w, height: h)
    }
}
