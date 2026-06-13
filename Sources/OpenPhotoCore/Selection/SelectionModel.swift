import Foundation
import CoreGraphics

/// One selectable grid item: its id plus an optional partner that selects with
/// it atomically (a Live Photo's video half). For timeline/folder grids the
/// partner is nil; the import grid passes the Live partner.
public struct SelectableItem: Sendable, Equatable {
    public let id: String
    public let partnerID: String?
    public init(id: String, partnerID: String? = nil) {
        self.id = id; self.partnerID = partnerID
    }
}

/// UI-agnostic selection state shared by every grid (import, timeline, folder).
/// Pure value type so it can be unit-tested and held in SwiftUI `@State`.
public struct SelectionModel: Equatable, Sendable {
    public private(set) var selected: Set<String> = []
    /// Index (into the caller's ordered item list) of the last plain tap — the
    /// origin for a subsequent shift-click range.
    public private(set) var anchor: Int?

    public init() {}

    public var count: Int { selected.count }
    public func contains(_ id: String) -> Bool { selected.contains(id) }

    public mutating func clear() {
        selected.removeAll(); anchor = nil
    }

    /// Flip one item (mirrors its partner).
    public mutating func toggle(_ item: SelectableItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
            if let p = item.partnerID { selected.remove(p) }
        } else {
            selected.insert(item.id)
            if let p = item.partnerID { selected.insert(p) }
        }
    }

    /// Add one item (mirrors its partner) — used for range and drag.
    public mutating func add(_ item: SelectableItem) {
        selected.insert(item.id)
        if let p = item.partnerID { selected.insert(p) }
    }

    /// Add every item (with partners). For "Select all".
    public mutating func selectAll(_ items: [SelectableItem]) {
        for it in items { add(it) }
    }

    /// Click = toggle + set anchor. Shift-click = additive range from the anchor.
    public mutating func tap(index: Int, items: [SelectableItem], extendingRange: Bool) {
        guard items.indices.contains(index) else { return }
        if extendingRange, let a = anchor, items.indices.contains(a) {
            for i in min(a, index)...max(a, index) { add(items[i]) }
            // anchor stays put across a range extension
        } else {
            toggle(items[index])
            anchor = index
        }
    }

    /// Whether the current rubber-band drag is in subtract mode (shift held at start).
    public private(set) var isDragSubtracting: Bool = false

    /// The selection as it was when the current rubber-band drag began. The live drag is
    /// recomputed from this baseline on every `updateDrag`, so a cell the marquee no longer
    /// covers reverts to its pre-drag state — the drag is only "finalised" on `endDrag`.
    /// nil when no drag is in progress.
    private var dragBaseline: Set<String>?

    /// Begin a rubber-band drag (clears the shift-anchor) and snapshot the current selection
    /// as the baseline. Pass `subtracting: true` when ⇧ is held at drag start to latch this
    /// drag into subtract mode; cells the marquee covers are *removed* instead of added.
    public mutating func beginDrag(subtracting: Bool = false) {
        anchor = nil
        isDragSubtracting = subtracting
        dragBaseline = selected
    }

    /// Recompute the live selection from the drag baseline + the cells the marquee currently
    /// covers. A cell that *leaves* the marquee reverts to its baseline state (add mode →
    /// back to unselected; subtract mode → back to selected); the selection isn't finalised
    /// until `endDrag`. Cells with no measured frame — e.g. scrolled out of view during
    /// auto-scroll — are left untouched so long sweeps keep what they already gathered.
    public mutating func updateDrag(rect: CGRect, frames: [String: CGRect],
                                    items: [SelectableItem]) {
        let base = dragBaseline ?? selected
        for it in items {
            guard let frame = frames[it.id] else { continue }
            let inRect = frame.intersects(rect)
            let keep = isDragSubtracting ? (base.contains(it.id) && !inRect)
                                         : (base.contains(it.id) || inRect)
            if keep {
                selected.insert(it.id)
                if let p = it.partnerID { selected.insert(p) }
            } else {
                selected.remove(it.id)
                if let p = it.partnerID { selected.remove(p) }
            }
        }
    }

    public mutating func endDrag() {
        isDragSubtracting = false
        dragBaseline = nil
    }
}
