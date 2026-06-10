import SwiftUI
import AVKit

/// Hosts AppKit's `AVPlayerView` directly. SwiftUI's `VideoPlayer` (the `_AVKit_SwiftUI` module)
/// aborts at runtime in this command-line/SPM-built bundle — a Swift metadata `fatalError`
/// (`getSuperclassMetadata`) while instantiating its representable, so any video crashed the app.
/// Wrapping the AppKit class ourselves sidesteps `_AVKit_SwiftUI` entirely.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
