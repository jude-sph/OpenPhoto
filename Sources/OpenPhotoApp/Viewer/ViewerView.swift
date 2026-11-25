import SwiftUI
import AVKit
import CoreImage
import OpenPhotoCore

/// Decoded full-res photos for the viewer, so stepping back/forth (and prefetched neighbors) is
/// instant instead of re-decoding. Bounded hard by BOTH count and total bytes — full-res images are
/// large (a 50MP photo is ~200MB decoded), so an unbounded cache would blow up memory. NSCache evicts
/// under pressure. Keyed by "instanceID|rotation".
nonisolated(unsafe) let viewerImageCache: NSCache<NSString, TileImageBox> = {
    let c = NSCache<NSString, TileImageBox>()
    c.countLimit = 6                              // current + a couple neighbors + a few revisits
    c.totalCostLimit = 768 * 1024 * 1024          // ~768 MB ceiling
    return c
}()

/// Owns every in-flight full-res decode for the viewer. Full-res bitmaps are 100–200 MB each and a
/// running ImageIO decode cannot be interrupted, so the number alive at once has to be bounded by
/// construction — holding an arrow key used to start one unowned decode per step (plus two
/// neighbour prefetches), which is the unbounded-image-memory shape that has OOM'd this app before.
///
/// - One decode per key ("instanceID|rotation"): a second request awaits the first.
/// - At most `maxConcurrent` decodes run; the rest queue, newest first (the photo on screen is
///   always the most recent request, so it never waits behind stale ones).
/// - `keepOnly` cancels requests the viewer has moved away from; a queued one then never starts.
/// Results land in `viewerImageCache` (which keeps its own count/byte bounds).
@MainActor
final class ViewerDecoder {
    static let shared = ViewerDecoder()
    private static let maxConcurrent = 2

    private struct Job {
        let instanceID: String
        let task: Task<CGImage?, Never>
    }
    private var jobs: [String: Job] = [:]
    private let slots = Slots(free: ViewerDecoder.maxConcurrent)

    static func key(instanceID: String, rotation: Int) -> String { "\(instanceID)|\(rotation)" }

    /// The decoded photo: from the cache, from the decode already in flight for it, or a new decode.
    /// nil if the file can't be decoded, or the request was cancelled before it started.
    func image(instanceID: String, url: URL, rotation: Int, priority: TaskPriority) async -> CGImage? {
        let key = Self.key(instanceID: instanceID, rotation: rotation)
        if let cached = viewerImageCache.object(forKey: key as NSString)?.image { return cached }
        if let job = jobs[key] { return await job.task.value }
        let slots = slots
        let task = Task.detached(priority: priority) { () -> CGImage? in
            await slots.acquire()
            // Checked only once a slot is ours: a request cancelled while queued costs nothing.
            let image: CGImage? = Task.isCancelled ? nil : autoreleasepool {
                FullResImage.decode(url: url, extraRotationCW: rotation)
            }
            if let image {
                viewerImageCache.setObject(TileImageBox(image), forKey: key as NSString,
                                           cost: image.width * image.height * 4)   // NSCache is thread-safe
            }
            await slots.release()
            return image
        }
        jobs[key] = Job(instanceID: instanceID, task: task)
        let image = await task.value
        if jobs[key]?.task == task { jobs[key] = nil }
        return image
    }

    /// Cancel every request that is not for one of `instanceIDs` (the open photo + its neighbours).
    func keepOnly(_ instanceIDs: Set<String>) {
        for (key, job) in jobs where !instanceIDs.contains(job.instanceID) {
            job.task.cancel()
            jobs[key] = nil
        }
    }

    /// Counting semaphore. Waiters resume newest-first.
    private actor Slots {
        private var free: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(free: Int) { self.free = free }
        func acquire() async {
            if free > 0 { free -= 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if let next = waiters.popLast() { next.resume() } else { free += 1 }
        }
    }
}

struct ViewerView: View {
    @Bindable var state: AppState
    /// What the stage draws for a photo: the full-res decode once it lands, and until then the
    /// photo's grid thumbnail (`shownIsFull == false`). ONE view shows both, laid out aspect-fit by the
    /// image's own shape, so the swap from thumbnail to full-res changes sharpness only — never size
    /// or position. (The old placeholder was an aspect-FILL thumbnail stretched over the whole stage,
    /// keyed at a size the grid never caches: a held arrow key flashed blank, then a huge cropped
    /// blur, then the photo.)
    @State private var shown: CGImage?
    @State private var shownIsFull = false
    /// "instanceID|rotation" of the photo `shown` belongs to — the zoom/pan reset key.
    @State private var shownKey = ""
    /// Non-rendering navigation bookkeeping (a class, so updating it never re-renders the viewer).
    @State private var nav = NavState()
    final class NavState {
        var indexHint: Int?
        var lastDelta = 0
        var lastStepAt = Date.distantPast
    }
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
    /// Position of the open item. Compares the fields `instanceID` is made of — `instanceID` itself
    /// is a computed string concatenation, which the old lookup built twice per element.
    /// Stepping moves by one, so the last known position (±1) is checked before the O(n) search —
    /// which was run several times per key press over the whole library.
    private var index: Int? {
        guard let open = state.openedItem else { return nil }
        let vaultID = open.vaultID, relPath = open.relPath
        let items = flatItems
        func matches(_ i: Int) -> Bool {
            items.indices.contains(i) && items[i].relPath == relPath && items[i].vaultID == vaultID
        }
        if let h = nav.indexHint {
            for i in [h, h + 1, h - 1] where matches(i) {
                nav.indexHint = i
                return i
            }
        }
        let found = items.firstIndex { $0.relPath == relPath && $0.vaultID == vaultID }
        nav.indexHint = found
        return found
    }

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
        // All gated on isEditingText so typing in the Inspector's caption/tag fields isn't hijacked
        // (e.g. "i" toggling the panel, Delete trashing the photo, arrows navigating away).
        .onKeyPress(.escape) { if state.isEditingText { return .ignored }; state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { if state.isEditingText { return .ignored }; step(-1); return .handled }
        .onKeyPress(.rightArrow) { if state.isEditingText { return .ignored }; step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { if state.isEditingText { return .ignored }; state.inspectorShown.toggle(); return .handled }
        // Space toggles video playback from the moment the viewer opens — without this, the stage
        // (not the AVPlayerView) holds focus initially, so Space "donks" until you click the player.
        .onKeyPress(.space) {
            guard !state.isEditingText, let player else { return .ignored }
            if player.rate == 0 {
                // A finished video parks at the end with rate 0, where play() would no-op — so replay
                // from the start. Otherwise (paused mid-video, or freshly opened) just resume.
                if let item = player.currentItem, item.duration.isNumeric, item.duration.seconds > 0,
                   player.currentTime().seconds >= item.duration.seconds - 0.25 {
                    player.seek(to: .zero)
                }
                player.play()
            } else {
                player.pause()
            }
            return .handled
        }
        .onKeyPress(.deleteForward) { if state.isEditingText { return .ignored }; deleteCurrent(); return .handled }
        .onKeyPress(.delete) { if state.isEditingText { return .ignored }; deleteCurrent(); return .handled }
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
        .onDisappear { tearDownPlayer(); ViewerDecoder.shared.keepOnly([]) }
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
                    // `content` can resolve to NO view (a video whose player isn't built yet); a frame
                    // on nothing takes no space, so the stack collapsed and the filmstrip jumped to the
                    // middle of the window until the player appeared. The clear fill always holds it.
                    ZStack { Color.clear; content }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    PlayerView(player: player)
                }
            } else if playingLive {
                if let player {
                    PlayerView(player: player)
                }
            } else if let shown {
                // GPU-composited zoom/pan via a CALayer — no SwiftUI re-render during gestures, so it
                // stays smooth on full-res photos. Rotation is baked into the image so pan/zoom stay
                // in the upright frame. ONE persistent view for every photo (no `.id`): stepping swaps
                // the layer's contents instead of tearing down and rebuilding an NSView per key press.
                ZoomableImageView(image: shown, resetKey: shownKey, isPreview: !shownIsFull)
            } else {
                Color.clear
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
        let openID = state.openedItem?.instanceID
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(flatItems, id: \.instanceID) { item in
                        // 52 pt tiles @2x need ~104 px — not the 512 px default.
                        ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: 128)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.instanceID == openID
                                              ? Theme.accent : .clear, lineWidth: 2))
                            .id(item.instanceID)
                            .onTapGesture { state.openedItem = item }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            // Start on the opened photo (no animation); later navigation animates.
            .onAppear { if let openID { proxy.scrollTo(openID, anchor: .center) } }
            .onChange(of: state.openedItem?.instanceID) { _, id in
                guard let id else { return }
                // Animate a single step; while a key is held (steps arriving faster than the
                // animation runs) jump instead, or the scroll animations queue up behind the photos.
                if Date().timeIntervalSince(nav.lastStepAt) < 0.25 {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
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
        nav.lastDelta = delta
        nav.lastStepAt = Date()
        nav.indexHint = j
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
        tearDownPlayer()
        playingLive = false
        liveURL = nil
        driveUnplugged = false
        guard let item = state.openedItem else {
            clearShown()
            ViewerDecoder.shared.keepOnly([])
            return
        }
        // Drop decode requests for anything that is no longer the open photo or a neighbour.
        ViewerDecoder.shared.keepOnly(Set(neighbourhood().map(\.instanceID)))
        // Read the rotation from the catalog (source of truth), not the possibly-stale `item`.
        liveRotation = rotation(for: item)
        guard let url = state.fullResURL(for: item) else {
            clearShown()
            if state.isDriveOnly(item) { driveUnplugged = true }   // drive-only, not connected
            return
        }
        if item.kind == MediaKind.video.rawValue {
            clearShown()
            // Bake any user display-rotation into the video itself (composition) so the player's
            // native controls stay upright — a .rotationEffect rotated the whole player, controls too.
            player = Self.makeVideoPlayer(url: url, rotationCW: liveRotation)
            return
        }
        // The Live-pair lookup is a catalog read + up to four `fileExists` calls — off the main thread.
        if let lib = state.library {
            let id = item.instanceID
            Task {
                let live = await Task.detached(priority: .userInitiated) {
                    Self.resolveLiveURL(for: item, photoURL: url, library: lib)
                }.value
                if state.openedItem?.instanceID == id { liveURL = live }   // still on this photo
            }
        }
        let rot = liveRotation
        let key = ViewerDecoder.key(instanceID: item.instanceID, rotation: rot)
        if let cached = viewerImageCache.object(forKey: key as NSString)?.image {
            // Cache hit (a prefetched neighbour, or a revisit) → full-res instantly.
            show(cached, key: key, full: true)
        } else {
            // Miss. Show the grid thumbnail NOW — synchronously from the shared tile cache, at the
            // photo's own shape — and sharpen in place when the decode lands. If the thumbnail isn't
            // in memory either, the previous photo stays up for the few ms it takes to read it
            // (never a blank stage).
            if let thumb = Self.cachedThumbnail(for: item) {
                show(FullResImage.applyRotation(thumb, degreesCW: rot), key: key, full: false)
            } else if let lib = state.library {
                Task {
                    let thumb = await Task.detached(priority: .userInitiated) {
                        await Self.loadThumbnail(for: item, library: lib)
                    }.value
                    // Only if still on this photo and the full-res hasn't beaten us to it.
                    guard let thumb, state.openedItem?.instanceID == item.instanceID,
                          liveRotation == rot, !(shownKey == key && shownIsFull) else { return }
                    show(FullResImage.applyRotation(thumb, degreesCW: rot), key: key, full: false)
                }
            }
            // While a key is held this task is cancelled by the next step before the decode returns,
            // so start the photo AHEAD (in the direction of travel) decoding now: by the time the user
            // gets there it is already in flight or cached. The decoder dedupes, caps concurrency at
            // two, runs newest-first, and drops queued work once it leaves the neighbourhood.
            prefetch(offset: nav.lastDelta)
            let decoded = await ViewerDecoder.shared.image(
                instanceID: item.instanceID, url: url, rotation: rot, priority: .userInitiated)
            // Ignore a result that arrived after the user already navigated away.
            guard state.openedItem?.instanceID == item.instanceID, liveRotation == rot else { return }
            if let decoded { show(decoded, key: key, full: true) }
        }
        prefetch(offset: nav.lastDelta)
        // The other neighbour only once navigation has paused: this task is cancelled by the next
        // step, so a held arrow key never gets here.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, state.openedItem?.instanceID == item.instanceID else { return }
        prefetchNeighbors()
    }

    private func show(_ image: CGImage, key: String, full: Bool) {
        shown = image; shownKey = key; shownIsFull = full
    }
    private func clearShown() { shown = nil; shownKey = ""; shownIsFull = false }

    /// The largest thumbnail of `item` already decoded in the shared tile cache (the grid the user
    /// just came from, or the filmstrip, has almost always put one there).
    private static func cachedThumbnail(for item: TimelineItem) -> CGImage? {
        for px in [512, 256, 128] {
            if let hit = tileMemoryCache.object(forKey: "\(item.instanceID)@\(px)" as NSString)?.image {
                return hit
            }
        }
        return nil
    }

    /// Read (or generate) the 512 px thumbnail off the main thread and share it with the tile cache.
    private nonisolated static func loadThumbnail(for item: TimelineItem,
                                                  library lib: LibraryService) async -> CGImage? {
        let hash = ContentHash(stringValue: item.hash)
        let kind = MediaKind(rawValue: item.kind) ?? .photo
        let px = ThumbnailStore.maxPixel
        var image: CGImage?
        if let url = lib.absoluteURL(for: item) {
            image = try? await lib.thumbnails.displayImage(for: hash, sourceURL: url, kind: kind, maxPixel: px)
        }
        if image == nil { image = await lib.thumbnails.cachedDisplayImage(for: hash, maxPixel: px) }
        if let image { cacheTileImage(image, forKey: "\(item.instanceID)@\(px)" as NSString) }
        return image
    }

    /// Start decoding the photo `offset` steps away (±1), if there is one and it isn't cached.
    private func prefetch(offset: Int) {
        guard offset != 0, let i = index else { return }
        let items = flatItems
        guard items.indices.contains(i + offset) else { return }
        prefetch(items[i + offset])
    }

    private func prefetch(_ it: TimelineItem) {
        guard it.kind != MediaKind.video.rawValue else { return }   // photos only
        let rot = rotation(for: it)
        let key = ViewerDecoder.key(instanceID: it.instanceID, rotation: rot) as NSString
        guard viewerImageCache.object(forKey: key) == nil,
              let url = state.fullResURL(for: it) else { return }
        let id = it.instanceID
        Task {
            _ = await ViewerDecoder.shared.image(instanceID: id, url: url, rotation: rot,
                                                 priority: .utility)
        }
    }

    /// The open item and its immediate neighbours (the only photos worth decoding right now).
    private func neighbourhood() -> [TimelineItem] {
        guard let i = index else { return state.openedItem.map { [$0] } ?? [] }
        let items = flatItems
        return [i - 1, i, i + 1].filter(items.indices.contains).map { items[$0] }
    }

    /// The open photo's display rotation, from the catalog (source of truth), falling back to the item.
    private func rotation(for item: TimelineItem) -> Int {
        (try? state.library?.catalog.rotation(forHash: item.hash)) ?? item.rotation
    }

    /// Warm the cache for the immediate neighbors so arrow-key stepping is instant. URL + rotation are
    /// read on the main actor; each decode runs off-main through `ViewerDecoder` (deduped, capped,
    /// cancelled if the viewer moves on before it starts). Bounded by the cache's count/byte limits.
    private func prefetchNeighbors() {
        guard let open = state.openedItem else { return }
        for it in neighbourhood() where it.instanceID != open.instanceID { prefetch(it) }
    }

    /// Build a video player, baking a user display-rotation into the frames via a video composition
    /// (so the AVPlayerView's native controls stay upright). No rotation → a plain player.
    private static func makeVideoPlayer(url: URL, rotationCW: Int) -> AVPlayer {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let deg = ((rotationCW % 360) + 360) % 360
        // Synchronous track access (deprecated but fine for a local file, and only for rotated videos)
        // — keeps the non-Sendable AVAssetTrack off any actor hop.
        guard deg != 0, let track = asset.tracks(withMediaType: .video).first else {
            return AVPlayer(playerItem: item)
        }
        let (transform, renderSize) = VideoRotation.render(
            naturalSize: track.naturalSize, preferred: track.preferredTransform, degreesCW: deg)
        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        comp.frameDuration = CMTime(value: 1, timescale: 30)
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        instr.layerInstructions = [layer]
        comp.instructions = [instr]
        item.videoComposition = comp
        return AVPlayer(playerItem: item)
    }


    private nonisolated static func livePairURL(photo: TimelineItem, pairHash: String,
                                                library lib: LibraryService) -> URL? {
        guard let rec = try? lib.catalog.instanceItem(hash: pairHash, vaultID: photo.vaultID),
              let vault = lib.vault(id: photo.vaultID) else { return nil }
        return vault.absoluteURL(forRelativePath: rec.relPath)
    }

    /// Resolve a Live Photo's video: prefer the catalog-recorded pair; otherwise
    /// fall back to a same-folder, same-basename .mov/.mp4 on disk (robust even if
    /// the pairing metadata didn't persist for an imported Live Photo).
    private nonisolated static func resolveLiveURL(for item: TimelineItem, photoURL: URL,
                                                   library: LibraryService) -> URL? {
        if let pair = item.livePairHash,
           let u = livePairURL(photo: item, pairHash: pair, library: library) {
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
    let image: CGImage
    /// Identity of the PHOTO being shown. Zoom/pan reset when it changes; a new image under the same
    /// key (thumbnail → full-res of the same photo) keeps them. nil → reset on every new image.
    var resetKey: String? = nil
    /// true while `image` is a low-res stand-in: "Copy Image" is withheld until the real one lands.
    var isPreview = false
    func makeNSView(context: Context) -> ZoomPanLayerView {
        let v = ZoomPanLayerView()
        v.setImageIfChanged(image, resetKey: resetKey, isPreview: isPreview)
        return v
    }
    // Only (re)set when the image instance actually changes — otherwise an
    // incidental SwiftUI re-render would re-decode the bitmap and reset the zoom
    // mid-gesture, which is what made zooming feel laggy.
    func updateNSView(_ v: ZoomPanLayerView, context: Context) {
        v.setImageIfChanged(image, resetKey: resetKey, isPreview: isPreview)
    }
}

final class ZoomPanLayerView: NSView {
    private let imageLayer = CALayer()
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var imageSize: CGSize = .zero
    private var currentImage: CGImage?
    private var currentKey: String?
    private var isPreview = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // top-left origin → CGImage renders upright

    func setImageIfChanged(_ image: CGImage, resetKey: String? = nil, isPreview: Bool = false) {
        self.isPreview = isPreview
        guard image !== currentImage else { return }
        let samePhoto = resetKey != nil && resetKey == currentKey
        currentImage = image
        currentKey = resetKey
        // Already fully decoded (off-main) — just hand the CGImage to the layer. No main-thread decode.
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit cross-fade/resize
        imageLayer.contents = image
        CATransaction.commit()
        // Layout uses only the image's SHAPE, so a thumbnail and the full-res of one photo land on
        // exactly the same frame.
        imageSize = CGSize(width: image.width, height: image.height)
        if !samePhoto { zoom = 1; pan = .zero }
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

    // Right-click the photo → "Copy Image". Self-contained in AppKit (the view already owns the
    // decoded full-res CGImage), so it works regardless of SwiftUI's context-menu quirks over an
    // NSViewRepresentable.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentImage != nil, !isPreview else { return nil }
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Image",
                                  action: #selector(copyImage(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        return menu
    }

    @objc private func copyImage(_ sender: Any?) {
        guard let cg = currentImage else { return }
        // The displayed CGImage is already the full-res decode with any display-rotation baked in,
        // so the pasted image is full-resolution and upright. Same writer ⌘C uses.
        ImageClipboard.copyDecoded(cg)
    }
}
