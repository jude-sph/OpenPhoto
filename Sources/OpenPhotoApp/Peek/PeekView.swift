import SwiftUI
import AVKit
import OpenPhotoCore

/// Thread-safe box so CGImage (a CF type) can live in NSCache<NSString, AnyObject>.
private final class PeekImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

nonisolated(unsafe) private let peekMemoryCache: NSCache<NSString, PeekImageBox> = {
    let c = NSCache<NSString, PeekImageBox>()
    c.countLimit = 2000
    return c
}()

/// One peek thumbnail. Mirrors ThumbView: synchronous cache read for instant recycled-cell display,
/// async refresh off a detached task. A snapshot item's real hash hits the imported cache; a raw
/// item's synthetic hash misses → generated from the file once.
struct PeekGridCell: View {
    let item: PeekItem
    let thumbnails: ThumbnailStore
    var targetPixel: Int = ThumbnailStore.maxPixel
    @State private var asyncImage: CGImage?

    private var cacheKey: NSString { "\(item.id)@\(targetPixel)" as NSString }

    var body: some View {
        let cached = peekMemoryCache.object(forKey: cacheKey)?.image ?? asyncImage
        ZStack {
            Theme.tile
            if let cached {
                Image(decorative: cached, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: cacheKey) {
            let key = cacheKey
            if let hit = peekMemoryCache.object(forKey: key)?.image { asyncImage = hit; return }
            let store = thumbnails, it = item, px = targetPixel
            let result: CGImage? = await Task.detached(priority: .userInitiated) {
                if let img = try? await store.displayImage(
                    for: it.thumbHash, sourceURL: it.sourceURL, kind: it.kind, maxPixel: px) {
                    return img
                }
                return await store.cachedDisplayImage(for: it.thumbHash, maxPixel: px)
            }.value
            if let img = result {
                peekMemoryCache.setObject(PeekImageBox(img), forKey: key)
                asyncImage = img
            }
        }
    }
}

/// The main-window-takeover peek surface: a labeled banner + a grid + an in-place full-screen viewer.
struct PeekView: View {
    let context: PeekContext
    let onDone: () -> Void

    @State private var openedPeek: PeekItem?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 2)]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Viewing \u{201c}\(context.sourceName)\u{201d}")
                        .font(.system(size: 15, weight: .semibold))
                    Text("temporary \u{00b7} not added to your library")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Done") { onDone() }.controlSize(.small)
                }
                .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
                Divider().overlay(Theme.hairline)

                if context.items.isEmpty {
                    ContentUnavailableView("No photos here", systemImage: "photo.on.rectangle")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(context.items) { item in
                                PeekGridCell(item: item, thumbnails: context.thumbnails)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { openedPeek = item }
                            }
                        }
                        .padding(2)
                    }
                }
            }
            if let opened = openedPeek {
                PeekViewer(items: context.items, initial: opened) { openedPeek = nil }
            }
        }
    }
}

/// A self-contained full-screen viewer for a peek (NOT AppState-coupled). Full-res is read from the
/// source file; reuses ZoomableImageView. Arrow keys navigate, esc closes.
private struct PeekViewer: View {
    let items: [PeekItem]
    let onClose: () -> Void

    @State private var current: PeekItem
    @State private var fullImage: NSImage?
    @State private var player: AVPlayer?
    @State private var loadFailed = false
    @FocusState private var focused: Bool

    init(items: [PeekItem], initial: PeekItem, onClose: @escaping () -> Void) {
        self.items = items
        self.onClose = onClose
        _current = State(initialValue: initial)
    }

    private var index: Int? { items.firstIndex(of: current) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(current.name).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 44)

            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.96))
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .task(id: current.id) { await loadFull() }
    }

    @ViewBuilder private var content: some View {
        if current.kind == .video {
            if let player { VideoPlayer(player: player) }
        } else if let fullImage {
            ZoomableImageView(image: fullImage).id(current.id)
        } else if loadFailed {
            Label("Full-res isn\u{2019}t available", systemImage: "externaldrive.badge.xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        current = items[j]
    }

    private func loadFull() async {
        fullImage = nil; player = nil; loadFailed = false
        if current.kind == .video {
            player = AVPlayer(url: current.sourceURL)
            return
        }
        let url = current.sourceURL
        // NSImage isn't Sendable; load raw Data in the detached task, build on the main actor.
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        if let data, let img = NSImage(data: data) { fullImage = img } else { loadFailed = true }
    }
}
