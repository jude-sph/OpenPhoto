import Foundation
import OpenPhotoCore

/// A grid's selectable items plus an id → position lookup, built ONCE when the grid's item list
/// changes (never per render). Lets a tap find its index, and the selection resolve to its items,
/// without walking the whole list — the timeline holds 10k–100k items, and select mode used to
/// run several full passes over them on every selection change.
struct SelectionIndex {
    /// The grid's items in display order — the order ⇧-click ranges run over.
    private(set) var ordered: [SelectableItem] = []
    private var positionByID: [String: Int] = [:]

    init() {}

    init(_ ordered: [SelectableItem]) {
        self.ordered = ordered
        var positions = [String: Int](minimumCapacity: ordered.count)
        // First occurrence wins, matching the `firstIndex(where:)` lookups this replaces.
        for (i, item) in ordered.enumerated() where positions[item.id] == nil { positions[item.id] = i }
        positionByID = positions
    }

    init(ids: some Sequence<String>) {
        self.init(ids.map { SelectableItem(id: $0) })
    }

    func position(of id: String) -> Int? { positionByID[id] }

    /// The selected members of `items`, in display order. `items` must be the list this index was
    /// built from; if it is not (the index is rebuilt just after the list changes, so one render can
    /// see the new list with the old index) this falls back to a plain filter, so the result is
    /// always exactly `items.filter { selection.contains(id($0)) }`.
    func selectedItems<T>(_ selection: SelectionModel, from items: [T], id: (T) -> String) -> [T] {
        guard selection.count > 0 else { return [] }
        guard ordered.count == items.count else { return items.filter { selection.contains(id($0)) } }
        let positions = selection.selected.compactMap { positionByID[$0] }.sorted()
        var out: [T] = []
        out.reserveCapacity(positions.count)
        for p in positions {
            guard id(items[p]) == ordered[p].id else {
                return items.filter { selection.contains(id($0)) }   // stale index: stay correct
            }
            out.append(items[p])
        }
        return out
    }
}
