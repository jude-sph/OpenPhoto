import SwiftUI
import AVKit
import OpenPhotoCore

struct ViewerView: View {
    @Bindable var state: AppState
    @State private var fullImage: NSImage?
    @State private var playingLive = false
    @State private var player: AVPlayer?
    @FocusState private var stageFocused: Bool
    @State private var liveURL: URL?   // paired Live Photo video, resolved on load

    private var flatItems: [TimelineItem] {
        state.viewerItems.isEmpty ? state.flatItems : state.viewerItems
    }
    private var index: Int? { flatItems.firstIndex { $0.hash == state.openedItem?.hash } }

    var body: some View {
        HStack(spacing: 0) {
            stage
            if state.inspectorShown, let item = state.openedItem {
                Divider().overlay(Theme.hairline)
                InspectorView(state: state, item: item)
                    .frame(width: Theme.inspectorWidth)
            }
        }
        .focusable()
        .focused($stageFocused)
        .onAppear { stageFocused = true }
        .onChange(of: state.openedItem?.hash) { stageFocused = true }
        .background(Color.black.opacity(0.96))
        .onKeyPress(.escape) { state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { state.inspectorShown.toggle(); return .handled }
        .onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
        .onKeyPress(.delete) { deleteCurrent(); return .handled }
        .task(id: state.openedItem?.hash) { await loadFull() }
        .onChange(of: playingLive) { _, live in
            if live, let url = liveURL {
                let p = AVPlayer(url: url)
                p.play()
                player = p
            } else if !live {
                player = nil
            }
        }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { state.openedItem = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if let item = state.openedItem {
                    Text(title(for: item)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                if liveURL != nil {
                    Button { playingLive.toggle() } label: {
                        Label(playingLive ? "Photo" : "Live",
                              systemImage: playingLive ? "photo" : "livephoto")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Button { state.inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 44)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            filmstrip
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        if let item = state.openedItem {
            if item.kind == MediaKind.video.rawValue {
                if let player {
                    VideoPlayer(player: player)
                }
            } else if playingLive {
                if let player {
                    VideoPlayer(player: player)
                }
            } else if let fullImage {
                // Self-contained zoom/pan state so pinching only re-renders the
                // image — not the filmstrip/inspector/toolbar. Keyed per photo so
                // state resets on navigation.
                ZoomableImage(image: fullImage)
                    .id(state.openedItem?.hash)
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(flatItems, id: \.hash) { item in
                        ThumbView(item: item, library: state.library!)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.hash == state.openedItem?.hash
                                              ? Theme.accent : .clear, lineWidth: 2))
                            .id(item.hash)
                            .onTapGesture { state.openedItem = item }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: state.openedItem?.hash) { _, hash in
                if let hash { withAnimation { proxy.scrollTo(hash, anchor: .center) } }
            }
        }
        .frame(height: 70)
        .background(.black.opacity(0.5))
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let j = i + delta
        guard flatItems.indices.contains(j) else { return }
        playingLive = false
        state.openedItem = flatItems[j]
    }

    private func deleteCurrent() {
        guard let item = state.openedItem else { return }
        step(1)
        if state.openedItem?.hash == item.hash { state.openedItem = nil }  // was last item
        Task {
            try? await state.library?.delete(item)
            try? state.refreshQueries()
        }
    }

    private func loadFull() async {
        fullImage = nil
        player = nil
        playingLive = false
        liveURL = nil
        guard let item = state.openedItem,
              let url = state.library?.absoluteURL(for: item) else { return }
        if item.kind == MediaKind.video.rawValue {
            player = AVPlayer(url: url)
            return
        }
        liveURL = resolveLiveURL(for: item, photoURL: url)
        // NSImage is not Sendable; load raw Data in the detached task, construct on main actor.
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        if let data {
            fullImage = NSImage(data: data)
        }
    }

    private func livePairURL(photo: TimelineItem, pairHash: String) -> URL? {
        guard let lib = state.library,
              let rec = try? lib.catalog.instanceItem(hash: pairHash, vaultID: photo.vaultID),
              let vault = lib.vault(id: photo.vaultID) else { return nil }
        return vault.absoluteURL(forRelativePath: rec.relPath)
    }

    /// Resolve a Live Photo's video: prefer the catalog-recorded pair; otherwise
    /// fall back to a same-folder, same-basename .mov/.mp4 on disk (robust even if
    /// the pairing metadata didn't persist for an imported Live Photo).
    private func resolveLiveURL(for item: TimelineItem, photoURL: URL) -> URL? {
        if let pair = item.livePairHash, let u = livePairURL(photo: item, pairHash: pair) {
            return u
        }
        guard item.kind == MediaKind.photo.rawValue else { return nil }
        let dir = photoURL.deletingLastPathComponent()
        let stem = photoURL.deletingPathExtension().lastPathComponent
        for ext in ["mov", "MOV", "mp4", "MP4"] {
            let candidate = dir.appendingPathComponent(stem + "." + ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func title(for item: TimelineItem) -> String {
        let d = Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Zoomable/pannable still image with its own isolated state — only this view
/// re-renders while zooming, keeping the rest of the viewer responsive. Two-finger
/// trackpad scroll pans (when zoomed), pinch zooms, double-click toggles zoom.
private struct ZoomableImage: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(pan)
                .padding(20)
            TrackpadZoomPan(
                onScroll: { d in
                    guard zoom > 1 else { return }
                    pan.width += d.width
                    pan.height += d.height
                },
                onMagnify: { m in
                    zoom = min(max(1, zoom * (1 + m)), 8)
                    if zoom <= 1 { pan = .zero }
                },
                onDoubleClick: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if zoom > 1 { zoom = 1; pan = .zero } else { zoom = 2.5 }
                    }
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Transparent AppKit layer that reports trackpad scroll, pinch, and double-click.
/// Using NSView (rather than SwiftUI gestures) gives smooth, precise trackpad
/// deltas and avoids per-frame whole-view gesture re-evaluation.
private struct TrackpadZoomPan: NSViewRepresentable {
    let onScroll: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll; v.onMagnify = onMagnify; v.onDoubleClick = onDoubleClick
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll; v.onMagnify = onMagnify; v.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        var onDoubleClick: (() -> Void)?
        override func scrollWheel(with e: NSEvent) {
            onScroll?(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
        }
        override func magnify(with e: NSEvent) { onMagnify?(e.magnification) }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { onDoubleClick?() }
        }
    }
}
