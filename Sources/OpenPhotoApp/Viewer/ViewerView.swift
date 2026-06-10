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
    @State private var driveUnplugged = false   // true when item is drive-only and drive is ejected

    private var flatItems: [TimelineItem] {
        state.viewerItems.isEmpty ? state.flatItems : state.viewerItems
    }
    private var index: Int? { flatItems.firstIndex { $0.instanceID == state.openedItem?.instanceID } }

    var body: some View {
        HStack(spacing: 0) {
            stage
            if state.inspectorShown, let item = state.openedItem {
                Divider().overlay(Theme.hairline)
                    .ignoresSafeArea(.container, edges: .top)
                InspectorView(state: state, item: item)
                    .frame(width: Theme.inspectorWidth)
            }
        }
        .focusable()
        .focusEffectDisabled()   // keep keyboard focus for arrow-keys, hide the blue focus ring
        .focused($stageFocused)
        .onAppear { stageFocused = true }
        .onChange(of: state.openedItem?.instanceID) { stageFocused = true }
        .background(Color.black.opacity(0.96))
        .onKeyPress(.escape) { state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { state.inspectorShown.toggle(); return .handled }
        .onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
        .onKeyPress(.delete) { deleteCurrent(); return .handled }
        .task(id: state.openedItem?.instanceID) { await loadFull() }
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
            if driveUnplugged {
                // Drive-only item and the drive is not connected — show thumbnail + prompt.
                VStack(spacing: 16) {
                    ThumbnailImage(timelineItem: item, library: state.library!)
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Label("Plug in the drive to view full-res",
                          systemImage: "externaldrive.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                }
            } else if item.kind == MediaKind.video.rawValue {
                if let player {
                    VideoPlayer(player: player)
                }
            } else if playingLive {
                if let player {
                    VideoPlayer(player: player)
                }
            } else if let fullImage {
                // GPU-composited zoom/pan via a CALayer — no SwiftUI re-render during
                // gestures, so it stays smooth on full-res photos. Keyed per photo.
                ZoomableImageView(image: fullImage)
                    .id(state.openedItem?.instanceID)
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(flatItems, id: \.instanceID) { item in
                        ThumbnailImage(timelineItem: item, library: state.library!)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.instanceID == state.openedItem?.instanceID
                                              ? Theme.accent : .clear, lineWidth: 2))
                            .id(item.instanceID)
                            .onTapGesture { state.openedItem = item }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: state.openedItem?.instanceID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
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
        // Drive-only assets are view-only — they have no local copy to move to a bin.
        guard let item = state.openedItem, !state.isDriveOnly(item) else { return }
        state.removeOpenedItem { await state.delete($0) }   // advance to next, delete in background
    }

    private func loadFull() async {
        fullImage = nil
        player = nil
        playingLive = false
        liveURL = nil
        driveUnplugged = false
        guard let item = state.openedItem else { return }
        guard let url = state.fullResURL(for: item) else {
            // Drive-only and the drive is not connected.
            if state.isDriveOnly(item) { driveUnplugged = true }
            return
        }
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

/// GPU-composited zoomable/pannable image. The CGImage is uploaded once as a
/// CALayer's contents; pinch/scroll/double-click only adjust the layer's frame
/// (a GPU transform), so there is no per-frame rasterization or SwiftUI re-render.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> ZoomPanLayerView {
        let v = ZoomPanLayerView()
        v.setImageIfChanged(image)
        return v
    }
    // Only (re)set when the image instance actually changes — otherwise an
    // incidental SwiftUI re-render would re-decode the bitmap and reset the zoom
    // mid-gesture, which is what made zooming feel laggy.
    func updateNSView(_ v: ZoomPanLayerView, context: Context) { v.setImageIfChanged(image) }
}

final class ZoomPanLayerView: NSView {
    private let imageLayer = CALayer()
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var imageSize: CGSize = .zero
    private var currentImage: NSImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // top-left origin → CGImage renders upright

    func setImageIfChanged(_ image: NSImage) {
        guard image !== currentImage else { return }
        currentImage = image
        var rect = CGRect(origin: .zero, size: image.size)
        imageLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        imageSize = image.size
        zoom = 1; pan = .zero
        relayout()
    }

    override func layout() { super.layout(); relayout() }

    private func relayout() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let inset: CGFloat = 20
        let avail = bounds.insetBy(dx: inset, dy: inset)
        let fit = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let w = imageSize.width * fit * zoom
        let h = imageSize.height * fit * zoom
        // Clamp pan so the image can't be dragged past its own edges.
        let maxX = max(0, (w - bounds.width) / 2)
        let maxY = max(0, (h - bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: (bounds.width - w) / 2 + pan.x,
                                  y: (bounds.height - h) / 2 + pan.y, width: w, height: h)
        CATransaction.commit()
    }

    override func scrollWheel(with e: NSEvent) {
        guard zoom > 1 else { return }
        pan.x += e.scrollingDeltaX
        pan.y += e.scrollingDeltaY
        relayout()
    }
    override func magnify(with e: NSEvent) {
        zoom = min(max(1, zoom * (1 + e.magnification)), 8)
        if zoom <= 1 { pan = .zero }
        relayout()
    }
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2 else { return }
        zoom = zoom > 1 ? 1 : 2.5
        pan = .zero
        relayout()
    }
}
