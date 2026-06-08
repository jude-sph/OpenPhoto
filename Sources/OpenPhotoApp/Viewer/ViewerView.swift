import SwiftUI
import AVKit
import OpenPhotoCore

struct ViewerView: View {
    @Bindable var state: AppState
    @State private var fullImage: NSImage?
    @State private var playingLive = false

    private var flatItems: [TimelineItem] { state.sections.flatMap(\.items) }
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
        .background(Color.black.opacity(0.96))
        .onKeyPress(.escape) { state.openedItem = nil; return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(KeyEquivalent("i")) { state.inspectorShown.toggle(); return .handled }
        .onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
        .onKeyPress(.delete) { deleteCurrent(); return .handled }
        .task(id: state.openedItem?.hash) { await loadFull() }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { state.openedItem = nil } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.plain)
                if let item = state.openedItem {
                    Text(title(for: item)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                if state.openedItem?.livePairHash != nil {
                    Button { playingLive.toggle() } label: {
                        Label("Live", systemImage: "livephoto")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Button { state.inspectorShown.toggle() } label: {
                    Image(systemName: "sidebar.right")
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
                if let url = state.library?.absoluteURL(for: item) {
                    VideoPlayer(player: AVPlayer(url: url))
                }
            } else if playingLive, let pair = item.livePairHash,
                      let pairURL = livePairURL(photo: item, pairHash: pair) {
                VideoPlayer(player: {
                    let p = AVPlayer(url: pairURL); p.play(); return p
                }())
            } else if let fullImage {
                Image(nsImage: fullImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .shadow(radius: 22)
                    .padding(20)
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
        guard let item = state.openedItem, item.kind == MediaKind.photo.rawValue,
              let url = state.library?.absoluteURL(for: item) else { return }
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

    private func title(for item: TimelineItem) -> String {
        let d = Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
