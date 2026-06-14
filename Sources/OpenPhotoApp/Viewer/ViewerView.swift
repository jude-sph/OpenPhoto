import SwiftUI
import AVKit
import CoreImage
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
    /// Live display rotation read from the CATALOG (the source of truth) for the open photo — the
    /// TimelineItem we were handed can be a stale copy from a grid list that wasn't refreshed after a
    /// rotate, which is why re-opening from the grid used to show the pre-rotation orientation.
    @State private var liveRotation = 0
    private var rotationDeg: Double { Double(liveRotation) }
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
        .onChange(of: state.openedItem?.instanceID) {
            // Re-assert focus (toggle off→on): leaving a video can drift the first responder, and
            // setting `true` when it's already `true` won't reclaim it — so arrow-key nav would die.
            stageFocused = false
            DispatchQueue.main.async { stageFocused = true }
        }
        .background(Color.black.opacity(0.96))
        .onKeyPress(.escape) { state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { state.inspectorShown.toggle(); return .handled }
        .onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
        .onKeyPress(.delete) { deleteCurrent(); return .handled }
        .task(id: "\(state.openedItem?.instanceID ?? "")|\(state.openedItem?.rotation ?? 0)") { await loadFull() }
        .onChange(of: playingLive) { _, live in
            if live, let url = liveURL {
                let p = AVPlayer(url: url)
                p.play()
                player = p
            } else if !live {
                tearDownPlayer()
            }
        }
        .onDisappear { tearDownPlayer() }
    }

    private var stage: some View {
        Group {
            if isFullWindowVideo, let player {
                // Video fills the whole stage — over the top bar, under the gallery — matching the
                // immersive full-window look of a zoomed photo (the gallery is the only overlay).
                // Back: Esc; toggle inspector: i.
                VStack(spacing: 0) {
                    // Video fills from the top edge down to JUST ABOVE the gallery — so the player's
                    // own controls sit above the gallery (like a photo rests above it), not hidden
                    // under it — with the top bar floating over the video.
                    ZStack(alignment: .top) {
                        PlayerView(player: player)
                            .rotationEffect(.degrees(rotationDeg))
                            .ignoresSafeArea(.container, edges: .top)   // still reaches the top edge
                        // A tight drop shadow on the controls keeps them legible over bright video
                        // without the top-of-window vignette a gradient background created.
                        topBar.shadow(color: .black.opacity(0.7), radius: 4)
                    }
                    galleryBar
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    galleryBar
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// True only for actual video clips (not playing Live Photos, which keep the bar visible for the
    /// Live/Photo toggle), and only once the player is ready.
    private var isFullWindowVideo: Bool {
        guard let item = state.openedItem, !driveUnplugged, player != nil else { return false }
        return item.kind == MediaKind.video.rawValue
    }

    private var topBar: some View {
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
                    PlayerView(player: player).rotationEffect(.degrees(rotationDeg))
                }
            } else if playingLive {
                if let player {
                    PlayerView(player: player).rotationEffect(.degrees(rotationDeg))
                }
            } else if let fullImage {
                // GPU-composited zoom/pan via a CALayer — no SwiftUI re-render during gestures, so it
                // stays smooth on full-res photos. Rotation is baked into fullImage so pan/zoom stay
                // in the upright frame. Keyed per photo + rotation.
                ZoomableImageView(image: fullImage)
                    .id("\(state.openedItem?.instanceID ?? "")|\(state.openedItem?.rotation ?? 0)")
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// The bottom gallery (filmstrip) with a thin always-visible handle to collapse/expand it.
    @ViewBuilder private var galleryBar: some View {
        VStack(spacing: 0) {
            Button { state.viewerGalleryShown.toggle() } label: {
                Image(systemName: state.viewerGalleryShown ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .background(.black.opacity(0.5))
            if state.viewerGalleryShown {
                filmstrip
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
        state.removeOpenedItem { await state.deletePhotos($0) }   // advance to next; delete the photo everywhere
    }

    /// Stop and release the current AV player. Pausing (and clearing the item) is required — merely
    /// dropping the `player` reference keeps the AVPlayer alive and playing audio until it happens to
    /// dealloc, and navigating away then back then stacks a second player (the doubled-audio bug).
    private func tearDownPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func loadFull() async {
        fullImage = nil
        tearDownPlayer()
        playingLive = false
        liveURL = nil
        driveUnplugged = false
        guard let item = state.openedItem else { return }
        // Read the rotation from the catalog (source of truth), not the possibly-stale `item`.
        liveRotation = (try? state.library?.catalog.rotation(forHash: item.hash)) ?? item.rotation
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
        if let data, let img = NSImage(data: data) {
            fullImage = Self.rotated(img, degrees: liveRotation)
        }
    }

    /// Rotate an NSImage 0/90/180/270 CW for display — the original file is never modified.
    private static func rotated(_ image: NSImage, degrees: Int) -> NSImage {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let orient: CGImagePropertyOrientation = d == 90 ? .right : (d == 180 ? .down : .left)
        let ci = CIImage(cgImage: cg).oriented(orient)
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return image }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
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
