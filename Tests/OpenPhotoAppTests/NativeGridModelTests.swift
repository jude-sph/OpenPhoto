import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore
@testable import OpenPhotoApp

private func item(_ hash: String, kind: MediaKind = .photo, duration: Double? = nil, live: Bool = false,
                  favorite: Bool = false, drive: Bool = false) -> TimelineItem {
    TimelineItem(hash: hash, kind: kind.rawValue, takenAtMs: 0, pixelWidth: 10, pixelHeight: 10,
                 latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                 durationSeconds: duration, livePairHash: live ? "pair" : nil, favorite: favorite, rating: 0,
                 caption: nil, tagsJSON: "[]", rotation: 0, vaultID: "v", relPath: hash + ".jpg",
                 dirPath: "", size: 1, driveRelPath: drive ? "d/" + hash : nil)
}

private func section(_ day: Int64, _ hashes: [String], title: String = "T") -> TimelineSection {
    TimelineSection(dayStartMs: day, title: title, items: hashes.map { item($0) })
}

// MARK: column maths (must match GridItem(.adaptive(minimum:), spacing:))

@Test func columnCountMatchesAdaptiveGridItem() {
    // floor((W + gap) / (min + gap))
    #expect(GridGeometry.columnCount(width: 1000, minCell: 100, gap: 3) == 9)    // 1003/103 = 9.7
    #expect(GridGeometry.columnCount(width: 1027, minCell: 100, gap: 3) == 10)   // 1030/103 = 10
    #expect(GridGeometry.columnCount(width: 50, minCell: 100, gap: 3) == 1)      // never zero
    #expect(GridGeometry.columnCount(width: 0, minCell: 100, gap: 3) == 1)
    #expect(GridGeometry.columnCount(width: 2560, minCell: 48, gap: 3) == 50)
}

@Test func cellsStretchToFillWidth() {
    let side = GridGeometry.cellSide(width: 1000, columns: 9, gap: 3)
    #expect(abs(side * 9 + 3 * 8 - 1000) < 0.001)
    #expect(side >= 100)
}

@Test func verticalStructureWithHeaders() {
    // 2 columns of 50 (width 103, gap 3); header 35.
    let g = GridGeometry(width: 103, minCell: 50, gap: 3, headerHeight: 35, counts: [3, 1], scale: 1)
    #expect(g.columns == 2)
    #expect(g.cell == 50)
    // Section 0: header 0…35, gap, rows at 38 and 91, bottom 141.
    #expect(g.headerFrame(0) == CGRect(x: 0, y: 0, width: 103, height: 35))
    #expect(g.itemFrame(GridIndex(section: 0, item: 0)) == CGRect(x: 0, y: 38, width: 50, height: 50))
    #expect(g.itemFrame(GridIndex(section: 0, item: 1)) == CGRect(x: 53, y: 38, width: 50, height: 50))
    #expect(g.itemFrame(GridIndex(section: 0, item: 2)) == CGRect(x: 0, y: 91, width: 50, height: 50))
    // Section 1 header after one gap.
    #expect(g.headerFrame(1)?.minY == 144)
    #expect(g.itemFrame(GridIndex(section: 1, item: 0)).minY == 182)
    #expect(g.contentHeight == 232)
}

@Test func noHeadersMeansNoHeaderSpace() {
    let g = GridGeometry(width: 103, minCell: 50, gap: 3, headerHeight: 0, counts: [2, 2], scale: 1)
    #expect(g.headerFrame(0) == nil)
    #expect(g.itemFrame(GridIndex(section: 0, item: 0)).minY == 0)
    #expect(g.itemFrame(GridIndex(section: 1, item: 0)).minY == 53)
    #expect(g.pinnedHeader(visibleTop: 10) == nil)
}

@Test func framesArePixelAligned() {
    let g = GridGeometry(width: 1001, minCell: 100, gap: 3, headerHeight: 0, counts: [30], scale: 2)
    for i in 0..<30 {
        let f = g.itemFrame(GridIndex(section: 0, item: i))
        for v in [f.minX, f.minY, f.maxX, f.maxY] { #expect((v * 2).rounded() == v * 2) }
    }
}

@Test func invalidIndexesAreSafe() {
    let g = GridGeometry(width: 300, minCell: 100, gap: 3, headerHeight: 35, counts: [2])
    #expect(!g.isValid(GridIndex(section: 0, item: 2)))
    #expect(!g.isValid(GridIndex(section: 1, item: 0)))
    #expect(!g.isValid(GridIndex(section: -1, item: 0)))
    #expect(g.itemFrame(GridIndex(section: 5, item: 5)) == .zero)
    #expect(g.headerFrame(9) == nil)
}

// MARK: hit-testing / rect queries

@Test func rectQueryReturnsExactlyIntersectingCells() {
    let g = GridGeometry(width: 1000, minCell: 90, gap: 3, headerHeight: 35, counts: [37, 5, 0, 12], scale: 2)
    let rects = [CGRect(x: 10, y: 0, width: 400, height: 300), CGRect(x: 0, y: 200, width: 1000, height: 900),
                 CGRect(x: 950, y: 500, width: 10, height: 10), CGRect(x: -50, y: -50, width: 20, height: 20),
                 CGRect(x: 0, y: 0, width: 1000, height: 100_000)]
    for r in rects {
        var brute: [GridIndex] = []
        for (s, n) in g.counts.enumerated() {
            for i in 0..<n where g.itemFrame(GridIndex(section: s, item: i)).intersects(r) {
                brute.append(GridIndex(section: s, item: i))
            }
        }
        #expect(g.items(intersecting: r) == brute)
    }
}

@Test func rectQueryToleratesHugeAndEmptyRects() {
    let g = GridGeometry(width: 500, minCell: 100, gap: 3, headerHeight: 35, counts: [10])
    #expect(g.items(intersecting: .null).isEmpty)
    #expect(g.items(intersecting: CGRect(x: 0, y: 0, width: 1e12, height: 1e12)).count == 10)
    #expect(g.items(intersecting: CGRect(x: 0, y: -1e9, width: 1e12, height: 1e18)).count == 10)
    #expect(GridGeometry.empty.items(intersecting: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
}

@Test func itemAtPointHitsCellsAndMissesGapsAndHeaders() {
    let g = GridGeometry(width: 103, minCell: 50, gap: 3, headerHeight: 35, counts: [3, 1], scale: 1)
    #expect(g.item(at: CGPoint(x: 10, y: 40)) == GridIndex(section: 0, item: 0))
    #expect(g.item(at: CGPoint(x: 60, y: 40)) == GridIndex(section: 0, item: 1))
    #expect(g.item(at: CGPoint(x: 51.5, y: 40)) == nil)    // horizontal gap
    #expect(g.item(at: CGPoint(x: 10, y: 10)) == nil)      // header
    #expect(g.item(at: CGPoint(x: 60, y: 100)) == nil)     // empty slot after the last item
    #expect(g.item(at: CGPoint(x: 10, y: 190)) == GridIndex(section: 1, item: 0))
    #expect(g.item(at: CGPoint(x: 10, y: 5000)) == nil)
    #expect(g.item(at: CGPoint(x: -1, y: 40)) == nil)
}

@Test func nearestItemClampsIntoTheGrid() {
    let g = GridGeometry(width: 103, minCell: 50, gap: 3, headerHeight: 35, counts: [3, 0, 1], scale: 1)
    #expect(g.nearestItem(to: CGPoint(x: 10, y: 5)) == GridIndex(section: 0, item: 0))      // on a header
    #expect(g.nearestItem(to: CGPoint(x: 90, y: 100)) == GridIndex(section: 0, item: 2))    // empty slot
    #expect(g.nearestItem(to: CGPoint(x: 10, y: 1e6)) == GridIndex(section: 2, item: 0))
    #expect(GridGeometry.empty.nearestItem(to: .zero) == nil)
}

@Test func pinnedHeaderFollowsTopAndIsPushedUp() {
    let g = GridGeometry(width: 103, minCell: 50, gap: 3, headerHeight: 35, counts: [3, 1], scale: 1)
    #expect(g.pinnedHeader(visibleTop: 0) == nil)            // natural header is in place
    let a = g.pinnedHeader(visibleTop: 20)
    #expect(a?.section == 0 && a?.y == 0)
    let b = g.pinnedHeader(visibleTop: 120)                  // bottom of s0 = 141 → pushed up by 14
    #expect(b?.section == 0 && b?.y == -14)
    #expect(g.pinnedHeader(visibleTop: 142) == nil)          // in the gap: s0 gone, s1's natural one shows
    #expect(g.pinnedHeader(visibleTop: 150)?.section == 1)
}

@Test func restoredTopKeepsAnchorAtSameViewportHeight() {
    let g = GridGeometry(width: 1000, minCell: 100, gap: 3, headerHeight: 0, counts: [500], scale: 1)
    let idx = GridIndex(section: 0, item: 200)
    let top = g.restoredTop(for: idx, offsetFromTop: 100, viewportHeight: 600)
    #expect(abs(g.itemFrame(idx).midY - top - 100) < 0.001)
    #expect(g.restoredTop(for: GridIndex(section: 0, item: 0), offsetFromTop: 500, viewportHeight: 600) == 0)
    #expect(g.restoredTop(for: GridIndex(section: 0, item: 499), offsetFromTop: 0, viewportHeight: 600)
            == g.contentHeight - 600)
}

// MARK: badges (TimelineTileBadges decisions)

@Test func kindBadgePriority() {
    #expect(TileBadgeSpec(item: item("a", live: true), backedUp: true).kind == .live)
    #expect(TileBadgeSpec(item: item("a", kind: .video, duration: 75), backedUp: true).kind
            == .video(duration: "1:15"))
    #expect(TileBadgeSpec(item: item("a", kind: .video, duration: nil), backedUp: true).kind
            == .video(duration: nil))
    #expect(TileBadgeSpec(item: item("a"), backedUp: true).kind == .none)
    #expect(TileBadgeSpec.durationText(.nan) == nil)
    #expect(TileBadgeSpec.durationText(3600) == "60:00")
}

@Test func presenceBadgePriority() {
    #expect(TileBadgeSpec(item: item("a"), backedUp: true).presence == .none)
    #expect(TileBadgeSpec(item: item("a"), backedUp: false).presence == .notBackedUp)
    #expect(TileBadgeSpec(item: item("a", drive: true), backedUp: true).presence == .onCanonicalDrive)
    #expect(TileBadgeSpec(item: item("a", drive: true), backedUp: false).presence == .onOtherDrive)
    #expect(TilePresenceBadge.notBackedUp.tooltip == "Not backed up to the canonical drive")
    #expect(TilePresenceBadge.none.tooltip == nil && TilePresenceBadge.none.symbol == nil)
    #expect(TilePresenceBadge.onOtherDrive.isWarning && !TilePresenceBadge.onCanonicalDrive.isWarning)
}

@Test func favoriteBadge() {
    #expect(TileBadgeSpec(item: item("a", favorite: true), backedUp: true).favorite)
    #expect(!TileBadgeSpec(item: item("a"), backedUp: true).favorite)
}

// MARK: update diff

@Test func sameStructureIgnoresMetadataButNotOrder() {
    let a = [section(1, ["x", "y"]), section(2, ["z"])]
    var b = a
    b[0] = TimelineSection(dayStartMs: 1, title: "T", items: [item("x", favorite: true), item("y")])
    #expect(GridUpdateDiff.sameStructure(a, b))
    #expect(!GridUpdateDiff.sameStructure(a, [section(1, ["y", "x"]), section(2, ["z"])]))
    #expect(!GridUpdateDiff.sameStructure(a, [section(1, ["x", "y"])]))
    #expect(!GridUpdateDiff.sameStructure(a, [section(1, ["x", "y"], title: "U"), section(2, ["z"])]))
    #expect(!GridUpdateDiff.sameStructure(a, [section(1, ["x"]), section(2, ["y", "z"])]))
}

@Test func sameStorageIsIdentityNotEquality() {
    let a = [section(1, ["x"])]
    let b = a
    let c = [section(1, ["x"])]
    #expect(GridUpdateDiff.sameStorage(a, b))
    #expect(!GridUpdateDiff.sameStorage(a, c))
    #expect(GridUpdateDiff.sameStorage([TimelineSection](), []))
}

@Test func findLocatesHash() {
    let s = [section(1, ["a", "b"]), section(2, ["c"])]
    #expect(GridUpdateDiff.find(hash: "c", in: s) == GridIndex(section: 1, item: 0))
    #expect(GridUpdateDiff.find(hash: "q", in: s) == nil)
}
