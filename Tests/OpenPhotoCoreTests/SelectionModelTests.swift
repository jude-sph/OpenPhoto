import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

private func items(_ ids: String...) -> [SelectableItem] { ids.map { SelectableItem(id: $0) } }

@Test func toggleAddsAndRemoves() {
    var s = SelectionModel()
    s.toggle(SelectableItem(id: "a"))
    #expect(s.contains("a") && s.count == 1)
    s.toggle(SelectableItem(id: "a"))
    #expect(!s.contains("a") && s.count == 0)
}

@Test func toggleMirrorsLivePartner() {
    var s = SelectionModel()
    s.toggle(SelectableItem(id: "photo", partnerID: "video"))
    #expect(s.contains("photo") && s.contains("video"))
    s.toggle(SelectableItem(id: "photo", partnerID: "video"))
    #expect(!s.contains("photo") && !s.contains("video"))
}

@Test func tapSetsAnchorAndToggles() {
    var s = SelectionModel()
    let list = items("a", "b", "c", "d")
    s.tap(index: 1, items: list, extendingRange: false)
    #expect(s.contains("b") && s.anchor == 1)
}

@Test func shiftTapSelectsInclusiveRange() {
    var s = SelectionModel()
    let list = items("a", "b", "c", "d")
    s.tap(index: 1, items: list, extendingRange: false)   // anchor at b
    s.tap(index: 3, items: list, extendingRange: true)    // range b…d
    #expect(s.contains("b") && s.contains("c") && s.contains("d") && !s.contains("a"))
}

@Test func selectAllAddsEveryItemWithPartners() {
    var s = SelectionModel()
    s.selectAll([SelectableItem(id: "p", partnerID: "v"), SelectableItem(id: "q")])
    #expect(s.contains("p") && s.contains("v") && s.contains("q") && s.count == 3)
}

@Test func dragSelectsIntersectingCellsFromBase() {
    var s = SelectionModel()
    let list = items("a", "b", "c")
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 10, height: 10),
        "b": CGRect(x: 20, y: 0, width: 10, height: 10),
        "c": CGRect(x: 40, y: 0, width: 10, height: 10),
    ]
    s.toggle(SelectableItem(id: "c"))     // pre-existing selection survives the drag
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 25, height: 10), frames: frames, items: list)
    // "c" was pre-selected before beginDrag; verify it survived the additive drag.
    #expect(s.contains("a") && s.contains("b") && s.contains("c"))
    s.endDrag()
    // A fresh drag starts from the current selection, not the stale base.
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 100, y: 100, width: 1, height: 1), frames: frames, items: list)
    #expect(s.contains("a") && s.contains("b") && s.contains("c"))
}

@Test func shiftTapWithoutAnchorJustToggles() {
    var s = SelectionModel()
    // extendingRange with no prior anchor falls through to a plain toggle.
    s.tap(index: 2, items: items("a", "b", "c"), extendingRange: true)
    #expect(s.contains("c") && s.count == 1 && s.anchor == 2)
}

@Test func clearEmptiesSelectionAndAnchor() {
    var s = SelectionModel()
    s.tap(index: 0, items: items("a"), extendingRange: false)
    s.clear()
    #expect(s.count == 0 && s.anchor == nil)
}

@Test func dragIsAdditiveAndDoesNotDropCells() {
    // A drag only grows the selection — a cell once inside the band stays selected
    // even if a later (smaller) rect no longer covers it. This is what lets the
    // selection accumulate while the grid auto-scrolls under the pointer.
    var s = SelectionModel()
    let list = items("a", "b", "c")
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 10, height: 10),
        "b": CGRect(x: 20, y: 0, width: 10, height: 10),
        "c": CGRect(x: 40, y: 0, width: 10, height: 10),
    ]
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 50, height: 10), frames: frames, items: list)  // all
    #expect(s.contains("a") && s.contains("b") && s.contains("c"))
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 5, height: 10), frames: frames, items: list)    // only a
    #expect(s.contains("a") && s.contains("b") && s.contains("c"))   // b, c retained (additive)
}
