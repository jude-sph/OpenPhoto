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
    private var dragBase: Set<String>?

    public init() {}

    public var count: Int { selected.count }
    public func contains(_ id: String) -> Bool { selected.contains(id) }

    public mutating func clear() {
        selected.removeAll(); anchor = nil; dragBase = nil
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

    /// Snapshot the current selection as the base for a rubber-band drag.
    public mutating func beginDrag() { dragBase = selected; anchor = nil }

    /// Recompute selection = base ∪ (items whose frame intersects `rect`).
    public mutating func updateDrag(rect: CGRect, frames: [String: CGRect],
                                    items: [SelectableItem]) {
        var newSel = dragBase ?? selected
        for it in items where frames[it.id]?.intersects(rect) == true {
            newSel.insert(it.id)
            if let p = it.partnerID { newSel.insert(p) }
        }
        selected = newSel
    }

    public mutating func endDrag() { dragBase = nil }
}
