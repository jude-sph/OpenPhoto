import SwiftUI
import AVKit
import OpenPhotoCore

struct ViewerView: View {
    @Bindable var state: AppState
    @State private var fullImage: NSImage?
    @State private var playingLive = false
    @State private var player: AVPlayer?
    @FocusState private var stageFocused: Bool
    // Pinch-to-zoom + pan state (reset on photo change).
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
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
                Image(nsImage: fullImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .shadow(radius: 22)
                    .padding(20)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in zoom = min(max(1, lastZoom * v.magnification), 8) }
                            .onEnded { _ in lastZoom = zoom; if zoom <= 1 { resetZoom() } }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                guard zoom > 1 else { return }
                                pan = CGSize(width: lastPan.width + v.translation.width,
                                             height: lastPan.height + v.translation.height)
                            }
                            .onEnded { _ in lastPan = pan }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            if zoom > 1 { resetZoom() } else { zoom = 2.5; lastZoom = 2.5 }
                        }
                    }
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
        resetZoom()
        state.openedItem = flatItems[j]
    }

    private func resetZoom() {
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
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
        resetZoom()
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
