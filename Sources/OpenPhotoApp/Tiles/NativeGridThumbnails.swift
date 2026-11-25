import AppKit
import SwiftUI
import OpenPhotoCore

/// Loads grid thumbnails into the shared `tileMemoryCache` with a BOUNDED number of concurrent
/// loads. Visible requests run newest-first (LIFO: while scrolling, the cells that just appeared are
/// the ones on screen; older requests usually belong to cells already scrolled away and cancelled).
/// Prefetch requests only run when no visible request is waiting, and each prefetch call replaces
/// the previous prefetch set.
///
/// Requests are deduplicated by cache key. A cancelled request that has not started is dropped; one
/// already running finishes (the provider is not cancellable) and still fills the cache — it just
/// isn't delivered to anyone, and it keeps its concurrency slot until it ends, so the bound is real.
@MainActor
final class TileThumbnailLoader {
    typealias Provider = @Sendable (_ maxPixel: Int) async -> CGImage?

    private final class Job {
        let key: NSString
        let px: Int
        let provider: Provider
        var waiters: [Int: (CGImage) -> Void] = [:]
        var started = false
        var prefetch: Bool
        init(key: NSString, px: Int, provider: @escaping Provider, prefetch: Bool) {
            self.key = key; self.px = px; self.provider = provider; self.prefetch = prefetch
        }
    }

    private let maxConcurrent: Int
    private var jobs: [NSString: Job] = [:]
    private var visibleStack: [NSString] = []
    private var prefetchStack: [NSString] = []
    private var tokenKeys: [Int: NSString] = [:]
    private var nextToken = 0
    private var running = 0
    private var closed = false

    init(maxConcurrent: Int = 6) { self.maxConcurrent = max(1, maxConcurrent) }


    /// Ask for `key`; `completion` runs on the main actor with the image if it loads before the
    /// returned token is cancelled. The image is cached under `key` either way.
    func request(key: NSString, px: Int, provider: @escaping Provider,
                 completion: @escaping (CGImage) -> Void) -> Int {
        nextToken &+= 1
        let token = nextToken
        if let job = jobs[key] {
            job.waiters[token] = completion
            if !job.started { job.prefetch = false; visibleStack.append(key) }   // (re)bump to the top
        } else {
            let job = Job(key: key, px: px, provider: provider, prefetch: false)
            job.waiters[token] = completion
            jobs[key] = job
            visibleStack.append(key)
        }
        tokenKeys[token] = key
        compactIfNeeded()
        pump()
        return token
    }

    func cancel(_ token: Int) {
        guard let key = tokenKeys.removeValue(forKey: token), let job = jobs[key] else { return }
        job.waiters[token] = nil
        if job.waiters.isEmpty && !job.started && !job.prefetch { jobs[key] = nil }
    }

    /// Replace the prefetch set (nearest first). Unstarted prefetches from the previous call that are
    /// not in the new set and that no cell is waiting on are dropped.
    func prefetch(_ requests: [(key: NSString, px: Int, provider: Provider)]) {
        let wanted = Set(requests.map(\.key))
        for key in prefetchStack where !wanted.contains(key) {
            if let j = jobs[key], j.prefetch, !j.started, j.waiters.isEmpty { jobs[key] = nil }
        }
        prefetchStack.removeAll(keepingCapacity: true)
        // Stack: push farthest first so the nearest pops first.
        for r in requests.reversed() {
            if let j = jobs[r.key] {
                if j.prefetch && !j.started { prefetchStack.append(r.key) }   // keep, re-ordered
            } else {
                jobs[r.key] = Job(key: r.key, px: r.px, provider: r.provider, prefetch: true)
                prefetchStack.append(r.key)
            }
        }
        pump()
    }

    /// Drop everything queued (running loads finish into the cache, delivered to no one).
    func close() {
        closed = true
        for (_, job) in jobs where !job.started { jobs[job.key] = nil }
        for (_, job) in jobs { job.waiters.removeAll() }
        visibleStack.removeAll(); prefetchStack.removeAll(); tokenKeys.removeAll()
    }

    private func pump() {
        while !closed, running < maxConcurrent, let job = nextJob() { start(job) }
    }

    private func nextJob() -> Job? {
        while let key = visibleStack.popLast() {
            if let j = jobs[key], !j.started, !j.waiters.isEmpty { return j }
        }
        while let key = prefetchStack.popLast() {
            if let j = jobs[key], !j.started { return j }
        }
        return nil
    }

    private func start(_ job: Job) {
        job.started = true
        running += 1
        let provider = job.provider, px = job.px, key = job.key
        let priority: TaskPriority = job.prefetch ? .utility : .userInitiated
        Task { [weak self] in
            let image = await Task.detached(priority: priority) { await provider(px) }.value
            self?.finish(key: key, image: image)
        }
    }

    private func finish(key: NSString, image: CGImage?) {
        running -= 1
        let job = jobs.removeValue(forKey: key)
        if let image {
            cacheTileImage(image, forKey: key)
            if let job {
                for (token, deliver) in job.waiters {
                    tokenKeys[token] = nil
                    deliver(image)
                }
            }
        } else if let job {
            for token in job.waiters.keys { tokenKeys[token] = nil }
        }
        pump()
    }

    /// The stacks keep stale keys (cancelled jobs are skipped when popped); keep them bounded.
    private func compactIfNeeded() {
        if visibleStack.count > 4 * jobs.count + 512 {
            var seen = Set<NSString>()
            // Keep the LAST occurrence of each live key (its newest priority).
            visibleStack = visibleStack.reversed().filter { jobs[$0] != nil && seen.insert($0).inserted }.reversed()
        }
    }

    /// The same provider logic as `ThumbnailImage.init(timelineItem:library:…)`: the store's display
    /// thumbnail for the resolved file, else whatever is cached by hash.
    nonisolated static func provider(for item: TimelineItem, library: LibraryService) -> Provider {
        let lib = library
        let hash = ContentHash(stringValue: item.hash)
        let kind = MediaKind(rawValue: item.kind) ?? .photo
        let it = item
        return { px in
            if let url = lib.absoluteURL(for: it),
               let img = try? await lib.thumbnails.displayImage(
                   for: hash, sourceURL: url, kind: kind, maxPixel: px) {
                return img
            }
            return await lib.thumbnails.cachedDisplayImage(for: hash, maxPixel: px)
        }
    }
}

/// The tile chrome as bitmaps: each distinct glyph is rendered ONCE (per appearance and backing
/// scale) and shared by every tile as `layer.contents`, instead of a SwiftUI subtree per tile.
@MainActor
enum TileGlyphs {
    private static var cache: [String: CGImage] = [:]

    /// White glyph tint matching `.white.opacity(0.92)`.
    private static let glyphWhite = NSColor(white: 1, alpha: 0.92)

    /// The disc-backed glyph of `TimelineTileBadges.glyph`: a 10 pt symbol over a black 40% disc
    /// with 3 pt of padding. The caller insets it 3 pt from the tile edge.
    static func presence(_ badge: TilePresenceBadge, dark: Bool, scale: CGFloat) -> CGImage? {
        guard let symbol = badge.symbol else { return nil }
        let key = "p|\(symbol)|\(dark)|\(scale)"
        if let hit = cache[key] { return hit }
        let img = render(dark: dark, scale: scale) {
            discGlyph(symbol, color: badge.isWarning ? NSColor(Theme.amber) : glyphWhite)
        }
        cache[key] = img
        return img
    }

    static func favorite(scale: CGFloat) -> CGImage? {
        let key = "fav|\(scale)"
        if let hit = cache[key] { return hit }
        let img = render(dark: false, scale: scale) { discGlyph("heart.fill", color: glyphWhite) }
        cache[key] = img
        return img
    }

    /// The kind capsule of `TimelineTileBadges.capsule`: a 9 pt bold symbol (+ optional duration in
    /// 10 pt semibold monospaced digits), white, on a black 45% capsule, 6/3 pt padding.
    static func kind(_ badge: TileKindBadge, scale: CGFloat) -> CGImage? {
        let symbol: String, text: String?
        switch badge {
        case .none: return nil
        case .live: symbol = "livephoto"; text = nil
        case .video(let d): symbol = "play.fill"; text = d
        }
        let key = "k|\(symbol)|\(text ?? "")|\(scale)"
        if let hit = cache[key] { return hit }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }   // durations are open-ended
        let img = render(dark: false, scale: scale) { capsule(symbol: symbol, text: text) }
        cache[key] = img
        return img
    }

    /// The select-mode checkbox: `checkmark.circle.fill` (white tick on accent) or `circle` (white
    /// ring), 20 pt bold.
    static func check(selected: Bool, scale: CGFloat) -> CGImage? {
        let key = "chk|\(selected)|\(scale)"
        if let hit = cache[key] { return hit }
        let img = render(dark: false, scale: scale) { () -> (NSSize, (NSRect) -> Void)? in
            let name = selected ? "checkmark.circle.fill" : "circle"
            let colors: [NSColor] = selected ? [.white, NSColor(Theme.accent)] : [.white, NSColor(white: 0, alpha: 0.45)]
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors))
            guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return nil }
            let size = sym.size
            return (size, { rect in sym.draw(in: rect) })
        }
        cache[key] = img
        return img
    }

    // MARK: drawing

    private static func discGlyph(_ symbol: String, color: NSColor) -> (NSSize, (NSRect) -> Void)? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let s = sym.size
        let d = ceil(max(s.width, s.height) + 6)
        return (NSSize(width: d, height: d), { rect in
            NSColor(white: 0, alpha: 0.4).setFill()
            NSBezierPath(ovalIn: rect).fill()
            sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                width: s.width, height: s.height))
        })
    }

    private static func capsule(symbol: String, text: String?) -> (NSSize, (NSRect) -> Void)? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let s = sym.size
        let label = text.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }
        let t = label?.size() ?? .zero
        let contentW = s.width + (label != nil ? 3 + ceil(t.width) : 0)
        let contentH = max(s.height, ceil(t.height))
        let size = NSSize(width: ceil(contentW + 12), height: ceil(contentH + 6))
        return (size, { rect in
            NSColor(white: 0, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            sym.draw(in: NSRect(x: rect.minX + 6, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            if let label {
                label.draw(at: NSPoint(x: rect.minX + 6 + s.width + 3, y: rect.midY - t.height / 2))
            }
        })
    }

    /// Render `content` (a size + a draw-into-rect closure) into a bitmap at `scale`, with dynamic
    /// colours resolved for the given appearance.
    private static func render(dark: Bool, scale: CGFloat,
                               _ content: () -> (NSSize, (NSRect) -> Void)?) -> CGImage? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var out: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            guard let (size, draw) = content(), size.width > 0, size.height > 0 else { return }
            let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.current = previous
            out = ctx.makeImage()
        }
        return out
    }
}
