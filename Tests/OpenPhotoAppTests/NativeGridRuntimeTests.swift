import Testing
import AppKit
import SwiftUI
@testable import OpenPhotoCore
@testable import OpenPhotoApp

// Headless runtime checks of the real NSCollectionView-backed grid in an offscreen window (no
// library: tiles stay placeholders, nothing touches disk). They exercise the paths where
// NSCollectionView classically crashes — reloads that change counts, stale index paths, relayout
// while scrolled — plus marquee/click selection and the cache-hit configure cost.

private func mkItem(_ hash: String, rotation: Int = 0, favorite: Bool = false) -> TimelineItem {
    TimelineItem(hash: hash, kind: MediaKind.photo.rawValue, takenAtMs: 0, pixelWidth: 10, pixelHeight: 10,
                 latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                 durationSeconds: nil, livePairHash: nil, favorite: favorite, rating: 0,
                 caption: nil, tagsJSON: "[]", rotation: rotation, vaultID: "test", relPath: hash,
                 dirPath: "", size: 1, driveRelPath: nil)
}

private func mkSections(_ counts: [Int], prefix: String = "h") -> [TimelineSection] {
    var n = 0
    return counts.enumerated().map { s, c in
        let items = (0..<c).map { _ -> TimelineItem in n += 1; return mkItem("\(prefix)\(n)") }
        return TimelineSection(dayStartMs: Int64(s), title: "Section \(s)", items: items)
    }
}

@MainActor
private final class Harness {
    var selection = SelectionModel()
    var minCell: CGFloat = 132
    var opened: [String] = []
    let coordinator = NativePhotoGridCoordinator()
    let window: NSWindow
    let root: NativeGridContainerView

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        root = coordinator.makeView()
        root.frame = window.contentView!.bounds
        root.autoresizingMask = [.width, .height]
        window.contentView!.wantsLayer = true
        window.contentView!.addSubview(root)
    }

    func update(_ sections: [TimelineSection], headers: Bool = true, selectMode: Bool = false) {
        let flat = sections.flatMap(\.items)
        let grid = NativePhotoGrid(
            sections: sections, showHeaders: headers,
            minCellSize: minCell, setMinCellSize: { [unowned self] in self.minCell = $0 },
            library: nil, selectMode: selectMode,
            selection: Binding(get: { [unowned self] in self.selection }, set: { [unowned self] in self.selection = $0 }),
            selectionIndex: SelectionIndex(ids: flat.map(\.hash)),
            backedUp: [], onOpen: { [unowned self] in self.opened.append($0.hash) },
            contextMenu: { _ in nil })
        coordinator.update(from: grid)
        pump()
    }

    func pump() {
        root.layoutSubtreeIfNeeded()
        coordinator.collectionView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    var cv: GridCollectionView { coordinator.collectionView }
    var clip: NSClipView { coordinator.scrollView.contentView }

    func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        coordinator.scrollView.reflectScrolledClipView(clip)
        pump()
    }

    /// Every visible item (a ROW) must sit at a valid index path, and agree with the data source.
    func checkVisibleConsistency() {
        let g = coordinator.geometry
        #expect(cv.numberOfSections == g.sectionCount)
        for ip in cv.indexPathsForVisibleItems() {
            #expect(ip.count == 2)
            #expect(ip[0] < g.sectionCount && ip[1] < g.rows(inSection: ip[0]),
                    "visible row at stale index path \(ip)")
            #expect(cv.numberOfItems(inSection: ip[0]) == g.rows(inSection: ip[0]))
            #expect(coordinator.item(at: GridIndex(section: ip[0], item: ip[1] * g.columns)) != nil)
        }
    }
}

@MainActor
@Test func gridSurvivesReloadsZoomsAndScrolls() {
    let h = Harness()
    h.minCell = 48
    var sections = mkSections(Array(repeating: 40, count: 200))   // 8000 items
    h.update(sections)
    #expect(h.cv.numberOfSections == 200)
    #expect(h.cv.numberOfItems(inSection: 3) == h.coordinator.geometry.rows(inSection: 3))
    #expect(!h.cv.indexPathsForVisibleItems().isEmpty)
    h.checkVisibleConsistency()

    // Scroll deep, then shrink the data drastically (fewer sections, fewer items).
    h.scroll(to: 20_000)
    h.checkVisibleConsistency()
    sections = mkSections([5, 3, 1])
    h.update(sections)
    #expect(h.cv.numberOfSections == 3)
    h.checkVisibleConsistency()
    #expect(h.clip.bounds.minY <= max(0, h.coordinator.geometry.contentHeight - h.clip.bounds.height) + 0.5)

    // Grow again, zoom across every bucket while scrolled, toggle headers.
    sections = mkSections(Array(repeating: 25, count: 400))
    h.update(sections)
    h.scroll(to: 50_000)
    for m: CGFloat in [48, 60, 64, 100, 132, 220, 48] {
        h.minCell = m
        h.update(sections)
        h.checkVisibleConsistency()
    }
    h.update(sections, headers: false)
    h.checkVisibleConsistency()
    h.update(sections, headers: true)
    h.checkVisibleConsistency()

    // Same-structure update (metadata only) must not reload.
    var changed = sections
    changed[0] = TimelineSection(dayStartMs: 0, title: "Section 0",
                                 items: sections[0].items.map { mkItem($0.hash, rotation: 90, favorite: true) })
    h.update(changed)
    h.checkVisibleConsistency()

    // Empty, then back.
    h.update([])
    #expect(h.cv.numberOfSections == 0)
    h.update(sections)
    h.checkVisibleConsistency()

    // Resize narrower/wider while scrolled.
    h.scroll(to: 10_000)
    h.window.setContentSize(NSSize(width: 700, height: 900))
    h.pump()
    h.checkVisibleConsistency()
    #expect(abs(h.coordinator.geometry.width - h.clip.bounds.width) < 0.5)
    h.window.setContentSize(NSSize(width: 1800, height: 900))
    h.pump()
    h.checkVisibleConsistency()
    h.coordinator.teardown()
}

@MainActor
@Test func zoomKeepsTheAnchorItemOnScreen() {
    let h = Harness()
    h.minCell = 100
    let sections = mkSections(Array(repeating: 30, count: 100))
    h.update(sections)
    h.scroll(to: 30_000)
    let vis = h.clip.bounds
    let g0 = h.coordinator.geometry
    guard let anchor = g0.nearestItem(to: CGPoint(x: vis.midX, y: vis.midY)) else { Issue.record("no anchor"); return }
    let before = g0.itemFrame(anchor).midY - vis.minY
    h.minCell = 180
    h.update(sections)
    let after = h.coordinator.geometry.itemFrame(anchor).midY - h.clip.bounds.minY
    #expect(abs(after - before) < 2, "anchor moved on screen: \(before) → \(after)")
    h.coordinator.teardown()
}

@MainActor
@Test func clickOpensInBrowseAndTogglesInSelectMode() {
    let h = Harness()
    let sections = mkSections([10, 10])
    h.update(sections)
    let g = h.coordinator.geometry
    let p0 = CGPoint(x: g.itemFrame(GridIndex(section: 0, item: 0)).midX, y: g.itemFrame(GridIndex(section: 0, item: 0)).midY)
    h.coordinator.handleClick(at: p0, shift: false)
    #expect(h.opened == ["h1"])

    h.update(sections, selectMode: true)
    h.coordinator.handleClick(at: p0, shift: false)
    #expect(h.selection.selected == ["h1"])
    let f = g.itemFrame(GridIndex(section: 1, item: 2))   // flat index 12 → h13
    h.coordinator.handleClick(at: CGPoint(x: f.midX, y: f.midY), shift: true)
    #expect(h.selection.count == 13)                       // ⇧-range h1…h13
    // A click on a header or gap does nothing.
    h.coordinator.handleClick(at: CGPoint(x: 5, y: 5), shift: false)
    #expect(h.selection.count == 13)
    h.coordinator.teardown()
}

@MainActor
@Test func marqueeSelectsCoveredCellsAndRevertsUncovered() {
    let h = Harness()
    let sections = mkSections([60])
    h.update(sections, headers: false, selectMode: true)
    let g = h.coordinator.geometry
    let a = g.itemFrame(GridIndex(section: 0, item: 0))
    let b = g.itemFrame(GridIndex(section: 0, item: g.columns + 1))   // second row, second column
    func win(_ p: CGPoint) -> NSPoint { h.cv.convert(p, to: nil) }
    h.coordinator.beginMarquee(at: CGPoint(x: a.midX, y: a.midY), subtracting: false,
                               windowPoint: win(CGPoint(x: a.midX, y: a.midY)))
    h.coordinator.marqueeMoved(to: win(CGPoint(x: b.midX, y: b.midY)))
    #expect(h.selection.count == 4)
    // Shrink back to the first cell: the others revert.
    h.coordinator.marqueeMoved(to: win(CGPoint(x: a.midX + 1, y: a.midY + 1)))
    #expect(h.selection.selected == ["h1"])
    h.coordinator.endMarquee()
    #expect(h.selection.selected == ["h1"])
    h.coordinator.teardown()
}

@MainActor
@Test func cacheHitConfigureIsCheap() {
    let h = Harness()
    let sections = mkSections([2000])
    h.update(sections)
    // Seed the shared cache with a tiny image under each item's real key.
    let px = gridThumbnailPixels(forCellMin: h.minCell)
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    let img = ctx.makeImage()!
    let items = sections[0].items
    for it in items { cacheTileImage(img, forKey: "\(it.instanceID)@\(px)" as NSString) }

    let tile = TileCell(host: CALayer())
    tile.setFrame(CGRect(x: 0, y: 0, width: 100, height: 100))
    let loader = TileThumbnailLoader()
    var c = NativeTileContext()
    c.px = px
    c.density = GridCellDensity(cellMin: h.minCell)
    c.selectMode = true
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for it in items { tile.configure(item: it, ctx: c, loader: loader) }
    }
    let perCell = elapsed / items.count
    print("cache-hit configure: \(perCell) per cell")
    #expect(perCell < .microseconds(100))
    for it in items { tileMemoryCache.removeObject(forKey: "\(it.instanceID)@\(px)" as NSString) }
    h.coordinator.teardown()
}

@MainActor
@Test func denseGridScrollStepCost() {
    let h = Harness()
    h.window.setContentSize(NSSize(width: 2560, height: 1400))
    h.minCell = 48
    let sections = mkSections(Array(repeating: 100, count: 1000))   // 100k items
    let clock = ContinuousClock()
    let firstLoad = clock.measure { h.update(sections) }
    let visible = h.cv.indexPathsForVisibleItems().count
    let realised = h.cv.visibleItems().count
    let step = clock.measure {
        for i in 1...60 { h.scroll(to: CGFloat(i) * 120) }   // ~2.5 rows per step
    }
    let jump = clock.measure { h.scroll(to: 1_000_000) }
    print("dense: first load \(firstLoad), visible \(visible), realised \(realised), "
          + "avg scroll step \(step / 60), far jump \(jump)")
    h.checkVisibleConsistency()
    #expect(visible * h.coordinator.geometry.columns >= 1000)   // visible ROWS × columns
    #expect(step / 60 < .milliseconds(16))
    h.coordinator.teardown()
}

/// Badge placement and the rotation direction assume a row's layer space is y-down on screen.
@MainActor
@Test func rowLayerSpaceIsYDown() {
    let h = Harness()
    h.update(mkSections([30]), headers: false)
    guard let rowItem = h.cv.visibleItems().first as? PhotoRowItem, let rowLayer = rowItem.row.layer,
          let rootLayer = h.window.contentView?.layer else { Issue.record("no row"); return }
    let viaLayers = rowLayer.convert(CGPoint(x: 5, y: 2), to: rootLayer)
    let viaViews = rowItem.row.convert(NSPoint(x: 5, y: 2), to: h.window.contentView)
    #expect(abs(viaLayers.x - viaViews.x) < 0.5 && abs(viaLayers.y - viaViews.y) < 0.5,
            "layer \(viaLayers) vs view \(viaViews)")
    h.coordinator.teardown()
}

/// Renders one tile offscreen with a red-top / blue-bottom image and samples it: the thumbnail must
/// be upright, and a 90° display rotation must turn it clockwise (red → right edge).
@MainActor
@Test func tileRendersUprightAndRotatesClockwise() {
    func sample(rotation: Int) -> (top: NSColor?, right: NSColor?) {
        _ = NSApplication.shared
        let size = 100
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext origin is bottom-left: blue bottom half, red TOP half.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: 50))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 50, width: size, height: 50))
        let img = ctx.makeImage()!
        let item = mkItem("rot\(rotation)", rotation: rotation)
        let key = "\(item.instanceID)@256" as NSString
        cacheTileImage(img, forKey: key)
        defer { tileMemoryCache.removeObject(forKey: key) }

        let row = PhotoRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = row
        let tile = TileCell(host: row.layer!)
        tile.setFrame(CGRect(x: 0, y: 0, width: 100, height: 100))
        var c = NativeTileContext()
        c.px = 256
        c.density = GridCellDensity(cellMin: 40)   // no badges, square corners
        tile.configure(item: item, ctx: c, loader: TileThumbnailLoader())
        guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return (nil, nil) }
        row.cacheDisplay(in: row.bounds, to: rep)
        // NSBitmapImageRep pixel coordinates are top-left origin.
        let top = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 10)
        let right = rep.colorAt(x: rep.pixelsWide * 9 / 10, y: rep.pixelsHigh / 2)
        return (top, right)
    }
    func isRed(_ c: NSColor?) -> Bool {
        guard let c = c?.usingColorSpace(.deviceRGB) else { return false }
        return c.redComponent > 0.8 && c.blueComponent < 0.2
    }
    let upright = sample(rotation: 0)
    #expect(isRed(upright.top), "top pixel \(String(describing: upright.top))")
    let rotated = sample(rotation: 90)
    #expect(isRed(rotated.right), "right pixel \(String(describing: rotated.right))")
    #expect(!isRed(rotated.top), "top pixel after rotation \(String(describing: rotated.top))")
}

@MainActor
@Test func chromeGlyphsRenderOnceAndAreShared() {
    _ = NSApplication.shared
    let warn = TileGlyphs.presence(.notBackedUp, dark: false, scale: 2)
    #expect(warn != nil)
    #expect(TileGlyphs.presence(.notBackedUp, dark: false, scale: 2) === warn)   // cached, shared
    #expect(TileGlyphs.presence(.notBackedUp, dark: true, scale: 2) !== warn)    // amber differs by mode
    #expect(TileGlyphs.presence(.none, dark: false, scale: 2) == nil)
    #expect(TileGlyphs.favorite(scale: 2) != nil)
    #expect(TileGlyphs.check(selected: true, scale: 2) != nil)
    #expect(TileGlyphs.check(selected: false, scale: 2) != nil)
    #expect(TileGlyphs.kind(.none, scale: 2) == nil)
    let short = TileGlyphs.kind(.video(duration: nil), scale: 2)
    let long = TileGlyphs.kind(.video(duration: "12:34"), scale: 2)
    #expect(short != nil && long != nil && (long?.width ?? 0) > (short?.width ?? 0))
    #expect(TileGlyphs.kind(.live, scale: 2) != nil)
}
