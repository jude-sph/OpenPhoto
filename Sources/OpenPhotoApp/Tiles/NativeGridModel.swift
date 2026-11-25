import Foundation
import CoreGraphics
import OpenPhotoCore

// Pure (AppKit-free) parts of the native timeline grid: layout maths, hit-testing, badge decisions and
// the update diff. Kept separate from `NativePhotoGrid.swift` so they can be reasoned about — and unit
// tested — without a window.

/// A cell's position: section + item within it. (Not `IndexPath`, so this file needs no AppKit.)
struct GridIndex: Hashable, Sendable {
    var section: Int
    var item: Int
}

/// The whole grid's geometry, computed arithmetically from per-section item counts — O(sections) to
/// build, O(log sections + visible) to query. Never per-item storage: a 100k-item timeline costs the
/// same to lay out as a 100-item one (the reason this is a custom layout and not a flow layout, which
/// computes and stores a frame for every item on each invalidation — i.e. on every pinch-zoom tick).
///
/// Vertical structure mirrors the SwiftUI grid it replaces, `LazyVStack(spacing: gap)` of
/// `[header, LazyVGrid]` per section: header, gap, rows separated by gap, then gap before the next
/// section's header. Without headers (Continuous grouping) a section is just its rows.
struct GridGeometry: Equatable {
    let width: CGFloat
    let minCell: CGFloat
    let gap: CGFloat
    let headerHeight: CGFloat
    let scale: CGFloat
    let counts: [Int]

    let columns: Int
    let cell: CGFloat
    /// Per section: top of the header (== `itemsTops` when there are no headers), top of the first row,
    /// and bottom of the last row (== `itemsTops` for an empty section). All ascending.
    private(set) var headerTops: [CGFloat] = []
    private(set) var itemsTops: [CGFloat] = []
    private(set) var bottoms: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0

    static let empty = GridGeometry(width: 0, minCell: 100, gap: 0, headerHeight: 0, counts: [])

    /// Same column count as `GridItem(.adaptive(minimum: minCell), spacing: gap)`: as many columns of
    /// at least `minCell` as fit, gaps included.
    static func columnCount(width: CGFloat, minCell: CGFloat, gap: CGFloat) -> Int {
        guard width.isFinite, minCell.isFinite, minCell + gap > 0, width > 0 else { return 1 }
        let n = ((width + gap) / (minCell + gap)).rounded(.down)
        return max(1, Int(min(n, 10_000)))
    }

    /// The adaptive cell side: the columns stretched to fill the width exactly.
    static func cellSide(width: CGFloat, columns: Int, gap: CGFloat) -> CGFloat {
        let c = CGFloat(max(1, columns))
        return max(1, (max(0, width) - gap * (c - 1)) / c)
    }

    /// `columns`: force a column count (nil = the adaptive count for `width`). The grid's collection
    /// view shows one item per ROW, so its item counts depend on the column count; a width change
    /// therefore keeps the loaded column count (cells stretch) until the owner reloads with the new one.
    init(width: CGFloat, minCell: CGFloat, gap: CGFloat, headerHeight: CGFloat,
         counts: [Int], scale: CGFloat = 2, columns forcedColumns: Int? = nil) {
        self.width = max(0, width.isFinite ? width : 0)
        self.minCell = minCell
        self.gap = gap
        self.headerHeight = max(0, headerHeight)
        self.scale = scale > 0 ? scale : 1
        self.counts = counts
        let cols = max(1, forcedColumns ?? Self.columnCount(width: self.width, minCell: minCell, gap: gap))
        columns = cols
        cell = Self.cellSide(width: self.width, columns: cols, gap: gap)

        headerTops.reserveCapacity(counts.count)
        itemsTops.reserveCapacity(counts.count)
        bottoms.reserveCapacity(counts.count)
        var y: CGFloat = 0
        for (s, n) in counts.enumerated() {
            if s > 0 { y += gap }
            headerTops.append(y)
            if self.headerHeight > 0 { y += self.headerHeight + gap }
            itemsTops.append(y)
            let rows = (max(0, n) + cols - 1) / cols
            if rows > 0 { y += CGFloat(rows) * cell + CGFloat(rows - 1) * gap }
            bottoms.append(y)
        }
        contentHeight = y
    }

    var pitch: CGFloat { cell + gap }
    var sectionCount: Int { counts.count }
    var hasHeaders: Bool { headerHeight > 0 }

    func rows(inSection s: Int) -> Int {
        guard counts.indices.contains(s) else { return 0 }
        return (max(0, counts[s]) + columns - 1) / columns
    }

    func isValid(_ i: GridIndex) -> Bool {
        counts.indices.contains(i.section) && i.item >= 0 && i.item < counts[i.section]
    }

    private func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    /// Pixel-aligned frame of a cell (edges rounded to device pixels so tiles never straddle one).
    func itemFrame(_ i: GridIndex) -> CGRect {
        guard isValid(i) else { return .zero }
        let row = i.item / columns, col = i.item % columns
        let x = CGFloat(col) * pitch
        let y = itemsTops[i.section] + CGFloat(row) * pitch
        let x0 = px(x), x1 = px(x + cell), y0 = px(y), y1 = px(y + cell)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Pixel-aligned frame of a whole row (full width; same vertical edges as its cells).
    func rowFrame(section s: Int, row r: Int) -> CGRect {
        guard r >= 0, r < rows(inSection: s) else { return .zero }
        let y = itemsTops[s] + CGFloat(r) * pitch
        let y0 = px(y), y1 = px(y + cell)
        return CGRect(x: 0, y: y0, width: width, height: y1 - y0)
    }

    /// Every (section, row) whose row frame intersects `rect`, in order.
    func forEachRow(intersecting rect: CGRect, _ body: (_ section: Int, _ row: Int) -> Void) {
        guard !rect.isNull, pitch > 0, rect.maxX >= 0, rect.minX <= width else { return }
        for s in sections(overlappingMinY: rect.minY, maxY: rect.maxY) {
            let rows = rows(inSection: s)
            guard rows > 0 else { continue }
            let top = itemsTops[s]
            let r0 = max(0, Self.slot((rect.minY - top) / pitch, rows - 1))
            let r1 = min(rows - 1, Self.slot((rect.maxY - top) / pitch, rows - 1))
            guard r0 <= r1 else { continue }
            for r in r0...r1 where rowFrame(section: s, row: r).intersects(rect) { body(s, r) }
        }
    }

    /// The section header's natural (unpinned) frame, or nil without headers.
    func headerFrame(_ s: Int) -> CGRect? {
        guard hasHeaders, headerTops.indices.contains(s) else { return nil }
        return CGRect(x: 0, y: headerTops[s], width: width, height: headerHeight)
    }

    /// Index of the first element of the ascending `values` that is >= `y` (== count if none).
    private static func lowerBound(_ values: [CGFloat], _ y: CGFloat) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the last section whose `values[s] <= y` (strictly `<` when `strict`), or nil.
    private static func lastAtOrAbove(_ values: [CGFloat], _ y: CGFloat, strict: Bool = false) -> Int? {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if strict ? values[mid] < y : values[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// Sections whose vertical extent (header top … last row bottom) overlaps `minY…maxY`.
    func sections(overlappingMinY minY: CGFloat, maxY: CGFloat) -> Range<Int> {
        guard !counts.isEmpty, minY <= maxY else { return 0..<0 }
        let first = Self.lowerBound(bottoms, minY)
        var end = first
        while end < counts.count && headerTops[end] <= maxY { end += 1 }
        return first..<end
    }

    /// Clamp a floating row/column coordinate to an Int in -1…hi+1 (safe for huge/NaN rects).
    private static func slot(_ v: CGFloat, _ hi: Int) -> Int {
        guard v.isFinite else { return v > 0 ? hi + 1 : -1 }
        return Int(max(-1, min(CGFloat(hi + 1), v.rounded(.down))))
    }

    /// Every cell whose frame intersects `rect`, in section/item order. Cheap: visits only the rows
    /// and columns the rect spans.
    func items(intersecting rect: CGRect) -> [GridIndex] {
        var out: [GridIndex] = []
        forEachItem(intersecting: rect) { out.append($0) }
        return out
    }

    func forEachItem(intersecting rect: CGRect, _ body: (GridIndex) -> Void) {
        guard !rect.isNull, pitch > 0, rect.maxX >= 0, rect.minX <= width else { return }
        let c0 = max(0, Self.slot(rect.minX / pitch, columns - 1))
        let c1 = min(columns - 1, Self.slot(rect.maxX / pitch, columns - 1))
        guard c0 <= c1 else { return }
        for s in sections(overlappingMinY: rect.minY, maxY: rect.maxY) {
            let rows = rows(inSection: s)
            guard rows > 0 else { continue }
            let top = itemsTops[s]
            let r0 = max(0, Self.slot((rect.minY - top) / pitch, rows - 1))
            let r1 = min(rows - 1, Self.slot((rect.maxY - top) / pitch, rows - 1))
            guard r0 <= r1 else { continue }
            for r in r0...r1 {
                for c in c0...c1 {
                    let i = r * columns + c
                    guard i < counts[s] else { break }
                    let gi = GridIndex(section: s, item: i)
                    if itemFrame(gi).intersects(rect) { body(gi) }
                }
            }
        }
    }

    /// The cell under `point`, or nil over a gap / header / empty space.
    func item(at point: CGPoint) -> GridIndex? {
        guard pitch > 0, point.x >= 0, point.x <= width,
              let s = Self.lastAtOrAbove(itemsTops, point.y), point.y <= bottoms[s] else { return nil }
        let row = Self.slot((point.y - itemsTops[s]) / pitch, rows(inSection: s) - 1)
        let col = Self.slot(point.x / pitch, columns - 1)
        guard row >= 0, col >= 0, col < columns else { return nil }
        let gi = GridIndex(section: s, item: row * columns + col)
        guard isValid(gi), itemFrame(gi).contains(point) else { return nil }
        return gi
    }

    /// The cell nearest `point` (clamped into the grid) — the scroll anchor. nil only when empty.
    func nearestItem(to point: CGPoint) -> GridIndex? {
        guard !counts.isEmpty else { return nil }
        var s = Self.lastAtOrAbove(headerTops, point.y) ?? 0
        // Skip empty sections: forward first, then backward.
        if counts[s] == 0 {
            if let f = (s..<counts.count).first(where: { counts[$0] > 0 }) { s = f }
            else if let b = (0..<s).last(where: { counts[$0] > 0 }) { s = b }
            else { return nil }
        }
        let rows = rows(inSection: s)
        let row = min(rows - 1, max(0, Self.slot((point.y - itemsTops[s]) / pitch, rows - 1)))
        let col = min(columns - 1, max(0, Self.slot(point.x / pitch, columns - 1)))
        return GridIndex(section: s, item: min(counts[s] - 1, row * columns + col))
    }

    /// The header to float over the top of the viewport, and its y in VIEWPORT coordinates (0, or
    /// negative while the next section pushes it up). nil while a section's own in-content header is
    /// fully at or below the top (it is then the visible one), and without headers.
    func pinnedHeader(visibleTop: CGFloat) -> (section: Int, y: CGFloat)? {
        guard hasHeaders, let s = Self.lastAtOrAbove(headerTops, visibleTop, strict: true) else { return nil }
        let y = min(0, bottoms[s] - visibleTop - headerHeight)
        return y > -headerHeight ? (s, y) : nil
    }

    /// The scroll origin (top of the visible rect) that puts `index` back at the same viewport height
    /// it had (`offsetFromTop` = its old frame.midY − old visible top), clamped to the scrollable range.
    func restoredTop(for index: GridIndex, offsetFromTop: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let target = itemFrame(index).midY - offsetFromTop
        let maxTop = max(0, contentHeight - viewportHeight)
        return min(maxTop, max(0, target))
    }
}

// MARK: - Badge decisions

/// What the top-right "kind" capsule shows.
enum TileKindBadge: Equatable, Sendable {
    case none
    case live
    case video(duration: String?)
}

/// The one presence badge (bottom-left), by priority — shown only when there's something to know.
/// On-Mac + on-canonical (the safe, common case) shows nothing.
enum TilePresenceBadge: Equatable, Sendable {
    case none
    case onCanonicalDrive    // drive-only, but on the canonical: connect it for full-res
    case onOtherDrive        // drive-only, and NOT on the canonical
    case notBackedUp         // local, not on the canonical

    var symbol: String? {
        switch self {
        case .none: nil
        case .onCanonicalDrive: "externaldrive.fill"
        case .onOtherDrive: "externaldrive.badge.exclamationmark"
        case .notBackedUp: "exclamationmark.triangle.fill"
        }
    }
    /// Amber (warning) vs white glyph.
    var isWarning: Bool { self == .onOtherDrive || self == .notBackedUp }
    var tooltip: String? {
        switch self {
        case .none: nil
        case .onCanonicalDrive: "On the canonical drive \u{2014} connect it for full-res"
        case .onOtherDrive: "On a drive, not the canonical"
        case .notBackedUp: "Not backed up to the canonical drive"
        }
    }
}

/// The timeline badge set for one tile — exactly `TimelineTileBadges`' decisions, as data.
struct TileBadgeSpec: Equatable, Sendable {
    var kind: TileKindBadge
    var presence: TilePresenceBadge
    var favorite: Bool

    static let none = TileBadgeSpec(kind: .none, presence: .none, favorite: false)

    init(kind: TileKindBadge, presence: TilePresenceBadge, favorite: Bool) {
        self.kind = kind; self.presence = presence; self.favorite = favorite
    }

    init(isLive: Bool, isVideo: Bool, durationSeconds: Double?, onDriveOnly: Bool, backedUp: Bool,
         favorite: Bool) {
        if isLive { kind = .live }
        else if isVideo { kind = .video(duration: durationSeconds.flatMap(Self.durationText)) }
        else { kind = .none }
        if onDriveOnly { presence = backedUp ? .onCanonicalDrive : .onOtherDrive }
        else { presence = backedUp ? .none : .notBackedUp }
        self.favorite = favorite
    }

    init(item: TimelineItem, backedUp: Bool) {
        self.init(isLive: item.livePairHash != nil,
                  isVideo: item.kind == MediaKind.video.rawValue,
                  durationSeconds: item.durationSeconds,
                  onDriveOnly: item.driveRelPath != nil,
                  backedUp: backedUp,
                  favorite: item.favorite)
    }

    /// "m:ss", as the SwiftUI badge formats it. nil for a non-finite/negative duration (the SwiftUI
    /// version would trap converting NaN to Int).
    static func durationText(_ s: Double) -> String? {
        guard s.isFinite, s >= 0, s < Double(Int.max / 2) else { return nil }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Update diff

enum GridUpdateDiff {
    /// True when `a` and `b` lay out identically and show the same items in the same places — same
    /// sections (key + title), same item hashes in the same order. Then an update only needs the
    /// visible cells reconfigured (a favourite/rotation/presence change), not a reload. O(items),
    /// run only when the sections array was actually replaced.
    static func sameStructure(_ a: [TimelineSection], _ b: [TimelineSection]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.dayStartMs == y.dayStartMs, x.title == y.title, x.items.count == y.items.count
            else { return false }
        }
        for (x, y) in zip(a, b) {
            // A changed representative instance (same hash) is fine: reconfiguring re-keys the tile.
            for (p, q) in zip(x.items, y.items) where p.hash != q.hash { return false }
        }
        return true
    }

    /// Same array storage (cheap identity check — the arrays are retained, so an address can't be
    /// reused while we hold the old one). Equal counts of zero count as identical.
    static func sameStorage<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress }
        }
    }

    /// Locate `hash` in `sections`, or nil.
    static func find(hash: String, in sections: [TimelineSection]) -> GridIndex? {
        for (s, sec) in sections.enumerated() {
            if let i = sec.items.firstIndex(where: { $0.hash == hash }) { return GridIndex(section: s, item: i) }
        }
        return nil
    }
}
