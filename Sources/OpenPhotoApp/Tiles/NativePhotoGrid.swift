import AppKit
import SwiftUI
import OpenPhotoCore

/// The timeline's scrolling photo grid, in AppKit: an `NSCollectionView` (custom arithmetic layout)
/// inside an `NSScrollView`, with recycled items whose thumbnail is plain `layer.contents` and whose
/// chrome is a handful of `CALayer`s showing shared, pre-rendered glyph bitmaps. No SwiftUI and no
/// Auto Layout inside cells — a dense grid's scroll cost is the recycled rows, not view-tree churn.
///
/// Feature parity with the SwiftUI grid (`LazyVStack` of sections of `LazyVGrid` + `MediaGridCell`):
/// section headers that pin to the top, adaptive square cells (`gridMinSize`, `Theme.gridGap`),
/// pinch-to-zoom, the shared `tileMemoryCache` with the same keys/pixel buckets, `MediaTile` +
/// `TimelineTileBadges` chrome, click-to-open / select-mode toggle + ⇧-extend, marquee selection
/// with edge auto-scroll (into the same `SelectionModel`), and the Copy context menu.
struct NativePhotoGrid: NSViewRepresentable {
    let sections: [TimelineSection]
    let showHeaders: Bool
    /// `state.gridMinSize`, passed by value so the owning body depends on it (a slider change must
    /// re-run `updateNSView`); pinch writes go through `setMinCellSize`.
    let minCellSize: CGFloat
    let setMinCellSize: (CGFloat) -> Void
    var zoomRange: ClosedRange<CGFloat> = 48...220
    let library: LibraryService?
    let selectMode: Bool
    @Binding var selection: SelectionModel
    /// The selectable list (display order) + id → position lookup that taps / ⇧-ranges run over.
    let selectionIndex: SelectionIndex
    /// Hashes present on a canonical/backup drive (drives the presence badge).
    let backedUp: Set<String>
    let onOpen: (TimelineItem) -> Void
    /// The right-click menu for a tile (built when the menu opens).
    let contextMenu: (TimelineItem) -> NSMenu?

    func makeCoordinator() -> NativePhotoGridCoordinator { NativePhotoGridCoordinator() }

    func makeNSView(context: Context) -> NativeGridContainerView {
        context.coordinator.makeView()
    }

    func updateNSView(_ nsView: NativeGridContainerView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ nsView: NativeGridContainerView, coordinator: NativePhotoGridCoordinator) {
        coordinator.teardown()
    }
}

/// Everything a tile needs to configure itself, resolved once per change (not per cell).
struct NativeTileContext {
    var px: Int = 256
    var density: GridCellDensity = .regular
    var selectMode = false
    var selection = SelectionModel()
    var backedUp: Set<String> = []
    var dark = false
    var scale: CGFloat = 2
    var tileColor: CGColor = CGColor(gray: 0.5, alpha: 1)
    var library: LibraryService?
}

// MARK: - Coordinator

@MainActor
final class NativePhotoGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    /// Header row height: 16 pt bold title + 8 pt vertical padding, as the SwiftUI header.
    static let headerHeight: CGFloat = 35
    private static let edgeZone: CGFloat = 48
    static let dragThreshold: CGFloat = 8

    private var parent: NativePhotoGrid?
    let container = NativeGridContainerView()
    let scrollView = NSScrollView()
    let collectionView = GridCollectionView()
    let layout = NativeGridLayout()
    let overlayHeader = GridHeaderView(frame: .zero)
    let marquee = MarqueeView()
    let loader = TileThumbnailLoader(maxConcurrent: 6)

    private(set) var sections: [TimelineSection] = []
    private var ctx = NativeTileContext()
    private var minCell: CGFloat = 0
    private var showHeaders = false
    private var configured = false
    private var pinnedSection: Int?
    private var overlayKey: (section: Int, title: String, count: Int)?
    private var lastPrefetchTop: CGFloat = .nan

    // Marquee state (collection-view == content coordinates).
    private var dragAnchor: CGPoint?
    private var dragTouched: CGRect = .null
    private var dragWindowPoint: NSPoint = .zero
    private var edgeDir: CGFloat = 0
    private var autoScrollTimer: Timer?

    // Pinch state.
    private var pinchBase: CGFloat?
    private var pinchScale: CGFloat = 1

    private var clip: NSClipView { scrollView.contentView }
    var geometry: GridGeometry { layout.geometry }
    var selectModeActive: Bool { ctx.selectMode }

    // MARK: setup / teardown

    func makeView() -> NativeGridContainerView {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.wantsLayer = true

        layout.gap = Theme.gridGap
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.handler = self
        layout.onColumnsStale = { [weak self] in self?.ensureColumns() }
        collectionView.register(PhotoRowItem.self, forItemWithIdentifier: PhotoRowItem.identifier)
        collectionView.register(GridHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: GridHeaderView.identifier)
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView

        overlayHeader.isOverlay = true
        overlayHeader.overlayTarget = self
        overlayHeader.isHidden = true
        marquee.isHidden = true

        container.coordinator = self
        container.addSubview(scrollView)
        container.addSubview(overlayHeader)
        container.addSubview(marquee)

        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
        return container
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
        stopAutoScroll()
        loader.close()
        collectionView.dataSource = nil
        collectionView.delegate = nil
        collectionView.handler = nil
        overlayHeader.overlayTarget = nil
        container.coordinator = nil
    }

    // MARK: SwiftUI → AppKit

    /// Called on every SwiftUI pass of the owning view. Everything here is O(1) or O(visible) unless
    /// the sections array was actually replaced (array-storage identity, not `==`).
    func update(from p: NativePhotoGrid) {
        parent = p
        let first = !configured
        configured = true
        if first {
            resolveAppearance()
            ctx.library = p.library
            ctx.selectMode = p.selectMode
            ctx.selection = p.selection
            ctx.backedUp = p.backedUp
            minCell = p.minCellSize
            showHeaders = p.showHeaders
            updateDerivedContext()
            relayout(anchor: .none, reload: true) {
                sections = p.sections
                layout.counts = p.sections.map(\.items.count)
                layout.minCell = minCell
                layout.headerHeight = showHeaders ? Self.headerHeight : 0
            }
            return
        }

        var fullRefresh = false
        var selectionRefresh = false
        if ctx.library !== p.library { ctx.library = p.library; fullRefresh = true }
        if !(ctx.backedUp == p.backedUp) { ctx.backedUp = p.backedUp; fullRefresh = true }
        if ctx.selectMode != p.selectMode { ctx.selectMode = p.selectMode; selectionRefresh = true }
        if ctx.selection != p.selection { ctx.selection = p.selection; selectionRefresh = true }
        if !p.selectMode && dragAnchor != nil { cancelMarquee() }   // no state writes during an update

        if !GridUpdateDiff.sameStorage(p.sections, sections) {
            if GridUpdateDiff.sameStructure(sections, p.sections) {
                // Same items in the same places (a favourite / rotation / presence-only change):
                // swap the model and reconfigure what's on screen. Layout untouched.
                sections = p.sections
                fullRefresh = true
            } else {
                relayout(anchor: .top, reload: true) {
                    sections = p.sections
                    layout.counts = p.sections.map(\.items.count)
                }
                fullRefresh = false   // reload reconfigured every visible cell already
                selectionRefresh = false
            }
        }

        if p.showHeaders != showHeaders {
            showHeaders = p.showHeaders
            relayout(anchor: .top, reload: false) {
                layout.headerHeight = showHeaders ? Self.headerHeight : 0
            }
        }
        if p.minCellSize != minCell {
            if applyMinCell(p.minCellSize, anchor: .center) { fullRefresh = true }
        }

        if fullRefresh { refreshVisible() }
        else if selectionRefresh { refreshVisibleSelection() }
    }

    /// Apply a new minimum cell size, keeping `anchor` on the same item. Returns true when the pixel
    /// bucket or chrome density changed (visible tiles must be reconfigured).
    @discardableResult
    private func applyMinCell(_ value: CGFloat, anchor: AnchorMode) -> Bool {
        guard value != minCell else { return false }
        let oldPx = ctx.px, oldDensity = ctx.density
        relayout(anchor: anchor, reload: false) {
            minCell = value
            layout.minCell = value
            updateDerivedContext()
        }
        return ctx.px != oldPx || ctx.density != oldDensity
    }

    private func updateDerivedContext() {
        ctx.px = gridThumbnailPixels(forCellMin: minCell)
        ctx.density = GridCellDensity(cellMin: minCell)
    }

    func resolveAppearance() {
        let appearance = container.effectiveAppearance
        ctx.dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ctx.scale = container.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var color = ctx.tileColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor(Theme.tile).cgColor }
        ctx.tileColor = color
        if layout.scale != ctx.scale { layout.scale = ctx.scale; layout.invalidateLayout() }
    }

    func appearanceChanged() {
        guard configured else { return }
        resolveAppearance()
        refreshVisible()
        overlayHeader.needsDisplay = true
    }

    // MARK: relayout with a scroll anchor

    enum AnchorMode { case none, top, center, point(CGPoint) }

    private struct Anchor {
        let index: GridIndex
        let hash: String
        let offsetFromTop: CGFloat
    }

    private func captureAnchor(_ mode: AnchorMode) -> Anchor? {
        let vis = clip.bounds
        // At the very top, stay at the top.
        guard vis.height > 0, vis.minY > 0 else { return nil }
        let point: CGPoint
        switch mode {
        case .none: return nil
        case .top: point = CGPoint(x: vis.minX + 1, y: vis.minY + 1)
        case .center: point = CGPoint(x: vis.midX, y: vis.midY)
        case .point(let p): point = p
        }
        guard let gi = geometry.nearestItem(to: point), let item = item(at: gi) else { return nil }
        return Anchor(index: gi, hash: item.hash, offsetFromTop: geometry.itemFrame(gi).midY - vis.minY)
    }

    /// Mutate the model/geometry inputs, rebuild the geometry BEFORE any reload (the layout and the
    /// data source must agree on counts at every moment AppKit can ask), then put the anchor item
    /// back where it was on screen. The collection view's items are ROWS, so a change in the column
    /// count is a change in item counts: it always reloads, in the same step that changes it.
    private func relayout(anchor mode: AnchorMode, reload: Bool, _ mutate: () -> Void) {
        let anchor = captureAnchor(mode)
        mutate()
        let cols = GridGeometry.columnCount(width: clip.bounds.width, minCell: layout.minCell, gap: layout.gap)
        let mustReload = reload || cols != layout.columns
        layout.columns = cols
        layout.rebuild()
        if mustReload { collectionView.reloadData() }
        layout.invalidateLayout()
        sizeDocument()
        if let anchor, let target = resolve(anchor) {
            let top = geometry.restoredTop(for: target, offsetFromTop: anchor.offsetFromTop,
                                           viewportHeight: clip.bounds.height)
            scroll(toTop: top)
        } else if clip.bounds.minY > max(0, geometry.contentHeight - clip.bounds.height) {
            scroll(toTop: max(0, geometry.contentHeight - clip.bounds.height))
        }
        lastPrefetchTop = .nan
        updatePinnedHeader()
    }

    private func resolve(_ a: Anchor) -> GridIndex? {
        if let it = item(at: a.index), it.hash == a.hash { return a.index }
        if let found = GridUpdateDiff.find(hash: a.hash, in: sections) { return found }
        // The anchor item is gone: the same slot, clamped.
        guard !sections.isEmpty else { return nil }
        let s = min(a.index.section, sections.count - 1)
        let n = sections[s].items.count
        guard n > 0 else { return geometry.nearestItem(to: .zero) }
        return GridIndex(section: s, item: min(a.index.item, n - 1))
    }

    private func sizeDocument() {
        let size = NSSize(width: clip.bounds.width,
                          height: max(geometry.contentHeight, clip.bounds.height))
        if collectionView.frame.size != size { collectionView.setFrameSize(size) }
    }

    private func scroll(toTop top: CGFloat) {
        guard abs(clip.bounds.minY - top) > 0.25 else { return }
        clip.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: scrolling / resizing

    @objc private func clipBoundsChanged(_ note: Notification) {
        updatePinnedHeader()
        prefetchIfNeeded()
        if dragAnchor != nil { applyMarquee() }   // a wheel scroll mid-drag extends the marquee
    }

    @objc private func clipFrameChanged(_ note: Notification) {
        ensureColumns()
    }

    /// The loaded column count must follow the width. Compares COLUMN COUNTS (not widths): the layout
    /// may already have re-stretched to the new width in `prepare()` before this runs.
    func ensureColumns() {
        guard configured else { return }
        let natural = GridGeometry.columnCount(width: clip.bounds.width, minCell: layout.minCell, gap: layout.gap)
        if natural != layout.columns || abs(clip.bounds.width - geometry.width) > 0.5 {
            relayout(anchor: .top, reload: false) {}   // reloads itself if the column count changed
        } else {
            sizeDocument()
            updatePinnedHeader()
        }
    }

    func containerDidLayout() {
        scrollView.frame = container.bounds   // → clip frame notification → ensureColumns()
    }

    // MARK: pinned header (an overlay above the scroll view, not a pinned supplementary)

    /// The header of the section under the top edge floats over the viewport (pushed up by the next
    /// section), exactly as a pinned `LazyVStack` section header. The in-content header of that
    /// section is hidden while it floats, so the translucent background never double-draws.
    private func updatePinnedHeader() {
        guard showHeaders, let pin = geometry.pinnedHeader(visibleTop: clip.bounds.minY),
              sections.indices.contains(pin.section) else {
            overlayHeader.isHidden = true
            setPinnedSection(nil)
            return
        }
        let sec = sections[pin.section]
        if overlayKey?.section != pin.section || overlayKey?.title != sec.title
            || overlayKey?.count != sec.items.count {
            overlayHeader.configure(title: sec.title, count: sec.items.count)
            overlayKey = (pin.section, sec.title, sec.items.count)
        }
        let frame = NSRect(x: 0, y: pin.y, width: clip.frame.width, height: Self.headerHeight)
        if overlayHeader.frame != frame { overlayHeader.frame = frame }
        overlayHeader.isHidden = false
        setPinnedSection(pin.section)
    }

    private func setPinnedSection(_ s: Int?) {
        guard s != pinnedSection else { return }
        let kind = NSCollectionView.elementKindSectionHeader
        if let old = pinnedSection {
            collectionView.supplementaryView(forElementKind: kind, at: IndexPath(item: 0, section: old))?.isHidden = false
        }
        pinnedSection = s
        if let s {
            collectionView.supplementaryView(forElementKind: kind, at: IndexPath(item: 0, section: s))?.isHidden = true
        }
    }

    // MARK: prefetch

    /// About a screen ahead in the scroll direction, recomputed every quarter screen of travel.
    private func prefetchIfNeeded() {
        let vis = clip.bounds
        guard vis.height > 0, let lib = ctx.library else { return }
        guard !lastPrefetchTop.isNaN else { lastPrefetchTop = vis.minY; return }
        let dy = vis.minY - lastPrefetchTop
        guard abs(dy) >= vis.height / 4 else { return }
        lastPrefetchTop = vis.minY
        let ahead = dy > 0
            ? CGRect(x: 0, y: vis.maxY, width: vis.width, height: vis.height)
            : CGRect(x: 0, y: vis.minY - vis.height, width: vis.width, height: vis.height)
        let px = ctx.px
        var requests: [(key: NSString, px: Int, provider: TileThumbnailLoader.Provider)] = []
        geometry.forEachItem(intersecting: ahead) { gi in
            guard let item = item(at: gi) else { return }
            let key = "\(item.instanceID)@\(px)" as NSString
            if tileMemoryCache.object(forKey: key) == nil {
                requests.append((key, px, TileThumbnailLoader.provider(for: item, library: lib)))
            }
        }
        if dy < 0 { requests.reverse() }   // nearest first
        loader.prefetch(requests)
    }

    // MARK: model access

    func item(at gi: GridIndex) -> TimelineItem? {
        guard sections.indices.contains(gi.section) else { return nil }
        let items = sections[gi.section].items
        return items.indices.contains(gi.item) ? items[gi.item] : nil
    }

    private static func gridIndex(_ ip: IndexPath) -> GridIndex? {
        ip.count >= 2 ? GridIndex(section: ip[0], item: ip[1]) : nil
    }

    // MARK: cell refresh

    private func refreshVisible() {
        for ip in collectionView.indexPathsForVisibleItems() {
            guard let rowItem = collectionView.item(at: ip) as? PhotoRowItem else { continue }
            configure(rowItem.row, at: ip)
        }
    }

    private func refreshVisibleSelection() {
        for cell in collectionView.visibleItems() {
            (cell as? PhotoRowItem)?.row.applySelection(ctx)
        }
    }

    /// Local first (instant feedback), then out to SwiftUI (the selection bar).
    private func commitSelection(_ sel: SelectionModel) {
        ctx.selection = sel
        refreshVisibleSelection()
        parent?.selection = sel
    }

    // MARK: NSCollectionViewDataSource

    // Items are ROWS: (section, row). Counts come from the same geometry the layout uses, which only
    // changes columns/counts together with a reload (see `relayout`).

    func numberOfSections(in collectionView: NSCollectionView) -> Int { geometry.sectionCount }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        geometry.rows(inSection: section)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: PhotoRowItem.identifier, for: indexPath)
        guard let rowItem = cell as? PhotoRowItem else { return cell }
        rowItem.row.grid = self.collectionView
        configure(rowItem.row, at: indexPath)
        return cell
    }

    private func configure(_ row: PhotoRowView, at indexPath: IndexPath) {
        guard let gi = Self.gridIndex(indexPath), sections.indices.contains(gi.section),
              gi.item >= 0, gi.item < geometry.rows(inSection: gi.section) else {
            row.clear()   // stale index path: draw nothing rather than trap
            return
        }
        row.configure(section: gi.section, row: gi.item, items: sections[gi.section].items,
                      geometry: geometry, ctx: ctx, loader: loader)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeaderView.identifier,
                                                        for: indexPath)
        if let header = view as? GridHeaderView {
            header.grid = self.collectionView
            let s = indexPath.count >= 1 ? indexPath[0] : -1
            if sections.indices.contains(s) {
                header.configure(title: sections[s].title, count: sections[s].items.count)
            } else {
                header.configure(title: "", count: 0)
            }
            header.isHidden = (s == pinnedSection)
        }
        return view
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoRowItem)?.row.cancelLoads()
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplayingSupplementaryView view: NSView,
                        forElementOfKind elementKind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) {
        view.isHidden = false
    }

    // MARK: input (from GridCollectionView)

    func handleClick(at point: CGPoint, shift: Bool) {
        guard let parent, let gi = geometry.item(at: point), let item = item(at: gi) else { return }
        if ctx.selectMode {
            guard let idx = parent.selectionIndex.position(of: item.hash) else { return }
            var sel = ctx.selection
            sel.tap(index: idx, items: parent.selectionIndex.ordered, extendingRange: shift)
            commitSelection(sel)
        } else {
            parent.onOpen(item)
        }
    }

    func menu(at point: CGPoint) -> NSMenu? {
        guard let gi = geometry.item(at: point), let item = item(at: gi) else { return nil }
        return parent?.contextMenu(item)
    }

    func beginMarquee(at point: CGPoint, subtracting: Bool, windowPoint: NSPoint) {
        guard ctx.selectMode else { return }
        var sel = ctx.selection
        sel.beginDrag(subtracting: subtracting)
        dragAnchor = point
        dragTouched = .null
        dragWindowPoint = windowPoint
        commitSelection(sel)
    }

    func marqueeMoved(to windowPoint: NSPoint) {
        guard dragAnchor != nil else { return }
        dragWindowPoint = windowPoint
        applyMarquee()
        updateEdgeDirection()
    }

    private func cancelMarquee() {
        dragAnchor = nil
        dragTouched = .null
        stopAutoScroll()
        marquee.isHidden = true
    }

    func endMarquee() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        dragTouched = .null
        stopAutoScroll()
        marquee.isHidden = true
        var sel = ctx.selection
        sel.endDrag()
        commitSelection(sel)
    }

    /// Recompute the drag selection from the content-anchored rect (so rows auto-scrolled above the
    /// viewport stay inside it). Every cell the marquee has EVER covered this drag gets a frame, so a
    /// cell it no longer covers reverts to its pre-drag state — `SelectionModel.updateDrag` semantics,
    /// with frames from the layout maths instead of measured SwiftUI geometry.
    private func applyMarquee() {
        guard let anchor = dragAnchor else { return }
        let p = collectionView.convert(dragWindowPoint, from: nil)
        let rect = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                          width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        dragTouched = dragTouched.isNull ? rect : dragTouched.union(rect)
        var frames: [String: CGRect] = [:]
        var items: [SelectableItem] = []
        geometry.forEachItem(intersecting: dragTouched) { gi in
            guard let item = item(at: gi) else { return }
            frames[item.hash] = geometry.itemFrame(gi)
            items.append(SelectableItem(id: item.hash))
        }
        var sel = ctx.selection
        sel.updateDrag(rect: rect, frames: frames, items: items)
        if sel != ctx.selection { commitSelection(sel) }

        // The visible marquee, clamped to the viewport.
        let inContainer = container.convert(rect, from: collectionView)
        let shown = inContainer.intersection(scrollView.frame)
        if shown.isNull || (shown.width <= 0 && shown.height <= 0) {
            marquee.isHidden = true
        } else {
            marquee.frame = shown
            marquee.isHidden = false
        }
    }

    private func updateEdgeDirection() {
        let p = collectionView.convert(dragWindowPoint, from: nil)
        let vis = clip.bounds
        let vy = p.y - vis.minY
        edgeDir = vy < Self.edgeZone ? -1 : (vy > vis.height - Self.edgeZone ? 1 : 0)
        if edgeDir == 0 { stopAutoScroll() } else if autoScrollTimer == nil { startAutoScroll() }
    }

    private func startAutoScroll() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        edgeDir = 0
    }

    private func autoScrollTick() {
        guard dragAnchor != nil, edgeDir != 0 else { stopAutoScroll(); return }
        let maxTop = max(0, collectionView.frame.height - clip.bounds.height)
        let top = min(maxTop, max(0, clip.bounds.minY + 22 * edgeDir))
        scroll(toTop: top)        // bounds-change → applyMarquee()
    }

    func magnify(_ event: NSEvent) {
        guard let parent else { return }
        if event.phase == .began || pinchBase == nil { pinchBase = minCell; pinchScale = 1 }
        pinchScale *= (1 + event.magnification)
        let range = parent.zoomRange
        let value = min(range.upperBound, max(range.lowerBound, (pinchBase ?? minCell) * pinchScale))
        if value != minCell {
            let p = collectionView.convert(event.locationInWindow, from: nil)
            if applyMinCell(value, anchor: .point(p)) { refreshVisible() }
            parent.setMinCellSize(value)   // SwiftUI sees the value it already has → no second relayout
        }
        if event.phase == .ended || event.phase == .cancelled { pinchBase = nil }
    }
}

// MARK: - Views

/// The representable's root: hosts the scroll view, the floating section header and the marquee.
final class NativeGridContainerView: NSView {
    weak var coordinator: NativePhotoGridCoordinator?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        coordinator?.containerDidLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        coordinator?.appearanceChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        coordinator?.appearanceChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.appearanceChanged()
    }
}

/// The collection view with the grid's own mouse handling: click / ⇧-click, marquee drag (select mode
/// only), context menu, pinch. AppKit's built-in selection is off; scroll-wheel events never reach
/// these handlers, so a two-finger scroll can never start a selection.
final class GridCollectionView: NSCollectionView {
    weak var handler: NativePhotoGridCoordinator?
    private var downPoint: CGPoint?
    private var downShift = false
    private var dragging = false

    /// Never take keyboard focus — the window's SwiftUI shortcuts (⌘C, the viewer's keys) keep it.
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        downPoint = convert(event.locationInWindow, from: nil)
        downShift = event.modifierFlags.contains(.shift)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downPoint, let handler else { return }
        if !dragging {
            let p = convert(event.locationInWindow, from: nil)
            guard handler.selectModeActive, hypot(p.x - down.x, p.y - down.y) >= NativePhotoGridCoordinator.dragThreshold else { return }
            dragging = true
            handler.beginMarquee(at: down, subtracting: downShift, windowPoint: event.locationInWindow)
        }
        handler.marqueeMoved(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        let down = downPoint, wasDragging = dragging
        downPoint = nil
        dragging = false
        guard let handler else { return }
        if wasDragging { handler.endMarquee() }
        else if let down { handler.handleClick(at: down, shift: event.modifierFlags.contains(.shift)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        handler?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        handler?.magnify(event)
    }
}

/// A layer with no implicit animations (frame / contents / hidden changes apply instantly).
final class StillLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// One collection-view item = one ROW of the grid. NSCollectionView's per-item-view cost grows with
/// its number of item views (it walks its subviews on every insertion: ~0.2 ms per inserted view at
/// ~1,000 views — 20+ ms per scroll step at minimum zoom when every photo is its own item). A row
/// strip keeps the item-view count to the number of visible ROWS; the photos inside are plain layers.
final class PhotoRowItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativePhotoGridRow")
    var row: PhotoRowView { view as! PhotoRowView }

    override func loadView() { view = PhotoRowView(frame: .zero) }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.cancelLoads()
    }
}

/// A row strip: a flipped, layer-backed view whose layer hosts its tiles' layers directly (no view
/// per photo, no Auto Layout). Mouse input is forwarded to the grid, which hit-tests arithmetically.
final class PhotoRowView: NSView {
    weak var grid: GridCollectionView?
    private(set) var tiles: [TileCell] = []
    private var tooltips: [(rect: CGRect, text: String)] = []
    private var tooltipOwners: [NSString] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }       // sublayer geometry is y-down, like the content
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}               // nothing drawn: all content is sublayer state

    override func mouseDown(with event: NSEvent) { grid?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { grid?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { grid?.mouseUp(with: event) }
    override func magnify(with event: NSEvent) { grid?.magnify(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.menu(for: event) }

    /// Configure the tiles for `row` of `section`. `items` is that section's item array.
    func configure(section s: Int, row r: Int, items: [TimelineItem], geometry g: GridGeometry,
                   ctx: NativeTileContext, loader: TileThumbnailLoader) {
        guard let host = layer else { return }
        let cols = g.columns
        if tiles.count > cols {
            for t in tiles[cols...] { t.remove() }
            tiles.removeLast(tiles.count - cols)
        }
        while tiles.count < cols { tiles.append(TileCell(host: host)) }
        let origin = g.rowFrame(section: s, row: r).origin
        let start = r * cols
        for c in 0..<cols {
            let i = start + c
            if i >= 0, i < items.count {
                let f = g.itemFrame(GridIndex(section: s, item: i))
                tiles[c].setFrame(f.offsetBy(dx: -origin.x, dy: -origin.y))
                tiles[c].configure(item: items[i], ctx: ctx, loader: loader)
            } else {
                tiles[c].hide()
            }
        }
        updateTooltips()
    }

    func clear() {
        for t in tiles { t.hide() }
        updateTooltips()
    }

    func applySelection(_ ctx: NativeTileContext) {
        for t in tiles where t.isShown {
            t.applySelection(selectMode: ctx.selectMode,
                             selected: ctx.selectMode && ctx.selection.contains(t.itemHash), scale: ctx.scale)
        }
    }

    func cancelLoads() { for t in tiles { t.cancelLoad() } }

    /// Presence-badge tooltips, re-registered only when they actually change.
    private func updateTooltips() {
        var wanted: [(rect: CGRect, text: String)] = []
        for t in tiles { if let tip = t.tooltip { wanted.append(tip) } }
        guard wanted.count != tooltips.count
                || zip(wanted, tooltips).contains(where: { $0.rect != $1.rect || $0.text != $1.text })
        else { return }
        removeAllToolTips()
        tooltipOwners.removeAll(keepingCapacity: true)
        for tip in wanted {
            let owner = tip.text as NSString   // an NSString owner supplies its own text; held here
            tooltipOwners.append(owner)
            addToolTip(tip.rect, owner: owner, userData: nil)
        }
        tooltips = wanted
    }
}

/// One photo tile, as layers in its row's layer: the thumbnail (aspect-fill, rounded, rotated) and
/// lazily created chrome layers showing shared glyph bitmaps. z-order via `zPosition` (thumbnail,
/// badges, ring, checkbox — `MediaTile`'s order), so nothing is ever re-stacked.
@MainActor
final class TileCell {
    private unowned let host: CALayer
    private(set) var frame: CGRect = .zero
    private(set) var itemHash = ""
    private(set) var isShown = true
    private(set) var currentKey: NSString?
    private var shownID: String?
    private var image: CGImage?
    private var rotation = 0
    private var radius: CGFloat = -1
    private var loadToken: Int?
    private weak var loader: TileThumbnailLoader?

    private let imageLayer = StillLayer()
    private var kindLayer: StillLayer?
    private var presenceLayer: StillLayer?
    private var favoriteLayer: StillLayer?
    private var ringLayer: StillLayer?
    private var checkLayer: StillLayer?

    private var badges: TileBadgeSpec?
    private var badgesApplied = false
    private var badgeDark = false
    private var badgeScale: CGFloat = 0
    private var selectMode = false
    private var selected = false
    private var selectionApplied = false
    private var checkScale: CGFloat = 0
    private var tileColor: CGColor?

    init(host: CALayer) {
        self.host = host
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerCurve = .continuous
        imageLayer.zPosition = 0
        host.addSublayer(imageLayer)
    }

    /// The presence badge's tooltip, in the row's coordinates.
    var tooltip: (rect: CGRect, text: String)? {
        guard isShown, let text = badges?.presence.tooltip, let l = presenceLayer, !l.isHidden else { return nil }
        return (l.frame, text)
    }

    func remove() {
        cancelLoad()
        for l in [imageLayer, kindLayer, presenceLayer, favoriteLayer, ringLayer, checkLayer] {
            l?.removeFromSuperlayer()
        }
    }

    func cancelLoad() {
        if let t = loadToken { loader?.cancel(t) }
        loadToken = nil
    }

    /// An empty slot (the end of a section's last row) or a stale index path.
    func hide() {
        guard isShown else { return }
        isShown = false
        cancelLoad()
        currentKey = nil
        itemHash = ""
        for l in [imageLayer, kindLayer, presenceLayer, favoriteLayer, ringLayer, checkLayer] { l?.isHidden = true }
        badgesApplied = false
        selectionApplied = false
    }

    func setFrame(_ f: CGRect) {
        guard f != frame else { return }
        frame = f
        imageLayer.bounds = CGRect(origin: .zero, size: f.size)
        imageLayer.position = CGPoint(x: f.midX, y: f.midY)
        ringLayer?.frame = f
        layoutBadges()
    }

    /// Cache hit: a cache lookup + a few layer property sets. Miss: placeholder (or the same item's
    /// previous-size image) + a bounded, cancellable load.
    func configure(item: TimelineItem, ctx: NativeTileContext, loader: TileThumbnailLoader) {
        self.loader = loader
        if !isShown {
            isShown = true
            imageLayer.isHidden = false
        }
        itemHash = item.hash
        if tileColor !== ctx.tileColor { tileColor = ctx.tileColor; imageLayer.backgroundColor = ctx.tileColor }
        let r = ctx.density.squareCorners ? 0 : Theme.cellRadius
        if r != radius {
            radius = r
            imageLayer.cornerRadius = r
            ringLayer?.cornerRadius = r
        }
        if item.rotation != rotation {
            rotation = item.rotation
            // Display rotation is clockwise; in this y-down layer space a positive angle is clockwise.
            imageLayer.setAffineTransform(rotation == 0 ? .identity
                : CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
        }

        let id = item.instanceID
        let key = "\(id)@\(ctx.px)" as NSString
        if currentKey != key {
            cancelLoad()
            currentKey = key
            if let hit = tileMemoryCache.object(forKey: key)?.image {
                setImage(hit, id: id)
            } else {
                // A different ITEM → placeholder until it loads; the SAME item at a new pixel size
                // keeps showing what it has (zooming across a bucket would otherwise blank the grid).
                if shownID != id { setImage(nil, id: nil) }
                if let lib = ctx.library {
                    loadToken = loader.request(key: key, px: ctx.px,
                                               provider: TileThumbnailLoader.provider(for: item, library: lib)) {
                        [weak self] img in
                        guard let self, self.currentKey == key else { return }   // reused since
                        self.loadToken = nil
                        self.setImage(img, id: id)
                    }
                }
            }
        }

        let spec: TileBadgeSpec? = ctx.density.showBadges
            ? TileBadgeSpec(item: item, backedUp: ctx.backedUp.contains(item.hash)) : nil
        applyBadges(spec, dark: ctx.dark, scale: ctx.scale)
        applySelection(selectMode: ctx.selectMode, selected: ctx.selectMode && ctx.selection.contains(item.hash),
                       scale: ctx.scale)
    }

    private func setImage(_ img: CGImage?, id: String?) {
        shownID = img == nil ? nil : id
        guard image !== img else { return }
        image = img
        imageLayer.contents = img
    }

    // MARK: chrome

    private func makeLayer(z: CGFloat) -> StillLayer {
        let l = StillLayer()
        l.contentsGravity = .resize
        l.zPosition = z
        host.addSublayer(l)
        return l
    }

    private func applyBadges(_ spec: TileBadgeSpec?, dark: Bool, scale: CGFloat) {
        guard !badgesApplied || spec != badges || dark != badgeDark || scale != badgeScale else { return }
        badgesApplied = true
        badges = spec; badgeDark = dark; badgeScale = scale
        let kindImage = spec.flatMap { TileGlyphs.kind($0.kind, scale: scale) }
        let presenceImage = spec.flatMap { TileGlyphs.presence($0.presence, dark: dark, scale: scale) }
        let favImage = (spec?.favorite ?? false) ? TileGlyphs.favorite(scale: scale) : nil
        set(&kindLayer, image: kindImage, scale: scale, z: 1)
        set(&presenceLayer, image: presenceImage, scale: scale, z: 1)
        set(&favoriteLayer, image: favImage, scale: scale, z: 1)
        layoutBadges()
    }

    private func set(_ slot: inout StillLayer?, image: CGImage?, scale: CGFloat, z: CGFloat) {
        if let image {
            let l = slot ?? makeLayer(z: z)
            slot = l
            if (l.contents as AnyObject?) !== image { l.contents = image }
            l.contentsScale = scale
            l.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            l.isHidden = false
        } else if let l = slot, !l.isHidden {
            l.isHidden = true
            l.contents = nil
        }
    }

    func applySelection(selectMode mode: Bool, selected sel: Bool, scale s: CGFloat) {
        guard !selectionApplied || mode != selectMode || sel != selected || s != checkScale else { return }
        selectionApplied = true
        selectMode = mode; selected = sel; checkScale = s
        if mode && sel {
            let ring = ringLayer ?? makeLayer(z: 2)
            if ringLayer == nil {
                ring.borderWidth = 3
                ring.borderColor = NSColor(Theme.accent).cgColor
                ring.cornerCurve = .continuous
                ringLayer = ring
            }
            ring.frame = frame
            ring.cornerRadius = max(0, radius)
            ring.isHidden = false
        } else {
            ringLayer?.isHidden = true
        }
        if mode {
            set(&checkLayer, image: TileGlyphs.check(selected: sel, scale: s), scale: s, z: 3)
        } else {
            checkLayer?.isHidden = true
        }
        layoutBadges()
    }

    /// Insets from `TimelineTileBadges` / `MediaTile`: capsule 6 pt top-right, disc glyphs 3 pt
    /// bottom-left / bottom-right, checkbox 7 pt top-left. Row space is y-down.
    private func layoutBadges() {
        let f = frame
        if let l = kindLayer, !l.isHidden {
            l.position = CGPoint(x: f.maxX - 6 - l.bounds.width / 2, y: f.minY + 6 + l.bounds.height / 2)
        }
        if let l = presenceLayer, !l.isHidden {
            l.position = CGPoint(x: f.minX + 3 + l.bounds.width / 2, y: f.maxY - 3 - l.bounds.height / 2)
        }
        if let l = favoriteLayer, !l.isHidden {
            l.position = CGPoint(x: f.maxX - 3 - l.bounds.width / 2, y: f.maxY - 3 - l.bounds.height / 2)
        }
        if let l = checkLayer, !l.isHidden {
            l.position = CGPoint(x: f.minX + 7 + l.bounds.width / 2, y: f.minY + 7 + l.bounds.height / 2)
        }
    }
}

/// A section header ("Friday, June 6" … "N items"), used both in-content and as the floating
/// pinned overlay.
final class GridHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("NativePhotoGridHeader")
    weak var grid: GridCollectionView?
    /// The floating copy above the scroll view: it forwards scroll / pinch to the grid and swallows
    /// clicks (the SwiftUI pinned header occluded the tiles beneath it the same way).
    var isOverlay = false
    weak var overlayTarget: NativePhotoGridCoordinator?

    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        count.textColor = NSColor(Theme.textFaint)
        count.alignment = .right
        for l in [title, count] {
            l.drawsBackground = false
            l.isBordered = false
            l.isEditable = false
            l.isSelectable = false
            addSubview(l)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor(Theme.windowBG).withAlphaComponent(0.92).cgColor
    }

    func configure(title t: String, count n: Int) {
        if title.stringValue != t { title.stringValue = t }
        let c = "\(n) items"
        if count.stringValue != c { count.stringValue = c }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let cs = count.intrinsicContentSize, ts = title.intrinsicContentSize
        let cw = ceil(cs.width)
        count.frame = NSRect(x: bounds.width - 16 - cw, y: (h - cs.height) / 2, width: cw, height: cs.height)
        title.frame = NSRect(x: 16, y: (h - ts.height) / 2,
                             width: max(0, bounds.width - 32 - cw - 8), height: ts.height)
    }

    /// Labels never take events; the header handles (or forwards) them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func scrollWheel(with event: NSEvent) {
        if isOverlay { overlayTarget?.scrollView.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        if isOverlay { overlayTarget?.magnify(event) } else { grid?.magnify(with: event) }
    }
    override func mouseDown(with event: NSEvent) { if !isOverlay { grid?.mouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) { if !isOverlay { grid?.mouseDragged(with: event) } }
    override func mouseUp(with event: NSEvent) { if !isOverlay { grid?.mouseUp(with: event) } }
    override func rightMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// The rubber-band rectangle (accent 12% fill, 70% 1 pt border, 2 pt corners). Never hit-tested.
final class MarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        let accent = NSColor(Theme.accent)
        layer.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        layer.borderColor = accent.withAlphaComponent(0.7).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 2
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Layout

/// Arithmetic layout over `GridGeometry`: O(sections) rebuild, O(visible) queries, attributes cached
/// per index path until the next rebuild. Headers are laid out in place; pinning is done by the
/// coordinator's floating overlay, so scrolling never invalidates this layout.
final class NativeGridLayout: NSCollectionViewLayout {
    private(set) var geometry = GridGeometry.empty
    var counts: [Int] = [] { didSet { dirty = true } }
    var minCell: CGFloat = 132 { didSet { dirty = true } }
    var headerHeight: CGFloat = 0 { didSet { dirty = true } }
    var gap: CGFloat = Theme.gridGap { didSet { dirty = true } }
    var scale: CGFloat = 2 { didSet { dirty = true } }
    /// The column count the collection view's ROW counts were loaded with. Only the coordinator
    /// changes it, together with a reload; a bare width change re-stretches the cells instead.
    var columns = 1 { didSet { dirty = true } }
    private var dirty = true
    private var itemCache: [IndexPath: NSCollectionViewLayoutAttributes] = [:]

    private var availableWidth: CGFloat {
        guard let cv = collectionView else { return 0 }
        return cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
    }

    func rebuild() {
        geometry = GridGeometry(width: availableWidth, minCell: minCell, gap: gap,
                                headerHeight: headerHeight, counts: counts, scale: scale, columns: columns)
        itemCache.removeAll(keepingCapacity: true)
        dirty = false
    }

    /// Called (once per run-loop turn, never inside layout) when the width now fits a different
    /// column count than the one loaded — the owner then reloads with it.
    var onColumnsStale: (() -> Void)?
    private var staleNotified = false

    override func prepare() {
        super.prepare()
        if dirty || abs(availableWidth - geometry.width) > 0.5 { rebuild() }
        let natural = GridGeometry.columnCount(width: geometry.width, minCell: minCell, gap: gap)
        if natural != columns, !staleNotified {
            staleNotified = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.staleNotified = false
                self.onColumnsStale?()
            }
        }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.width, height: geometry.contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - geometry.width) > 0.5
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var out: [NSCollectionViewLayoutAttributes] = []
        geometry.forEachRow(intersecting: rect) { s, r in out.append(rowAttributes(section: s, row: r)) }
        if geometry.hasHeaders {
            for s in geometry.sections(overlappingMinY: rect.minY, maxY: rect.maxY) {
                if let f = geometry.headerFrame(s), f.intersects(rect) { out.append(headerAttributes(s, f)) }
            }
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.count >= 2, indexPath[1] >= 0,
              indexPath[1] < geometry.rows(inSection: indexPath[0]) else { return nil }
        return rowAttributes(section: indexPath[0], row: indexPath[1])
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader, indexPath.count >= 1,
              let f = geometry.headerFrame(indexPath[0]) else { return nil }
        return headerAttributes(indexPath[0], f)
    }

    private func rowAttributes(section s: Int, row r: Int) -> NSCollectionViewLayoutAttributes {
        let ip = IndexPath(item: r, section: s)
        if let hit = itemCache[ip] { return hit }
        let a = NSCollectionViewLayoutAttributes(forItemWith: ip)
        a.frame = geometry.rowFrame(section: s, row: r)
        if itemCache.count > 20_000 { itemCache.removeAll(keepingCapacity: true) }
        itemCache[ip] = a
        return a
    }

    private func headerAttributes(_ s: Int, _ frame: CGRect) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            with: IndexPath(item: 0, section: s))
        a.frame = frame
        a.zIndex = 0   // same as items: AppKit then appends instead of scanning subviews per insert
        return a
    }
}

// MARK: - Context menu

/// An `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

extension ImageClipboard {
    /// The AppKit twin of `CopyMenuButton`: one "Copy…" item whose title states the exact outcome,
    /// disabled when nothing in `items` can be read right now.
    static func contextMenu(for items: [TimelineItem], state: AppState) -> NSMenu {
        let plan = ClipboardCopyPlan.make(for: items)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = ClosureMenuItem(title: plan.title) { ImageClipboard.copy(plan, state: state) }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.isEnabled = canCopy(items, state: state)
        menu.addItem(copy)
        return menu
    }
}
