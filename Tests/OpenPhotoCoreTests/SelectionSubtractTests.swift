import Testing
import Foundation
import CoreGraphics
@testable import OpenPhotoCore

// MARK: – Helpers

private func makeItems(_ ids: String...) -> [SelectableItem] { ids.map { SelectableItem(id: $0) } }

private let sampleFrames: [String: CGRect] = [
    "a": CGRect(x:  0, y: 0, width: 10, height: 10),
    "b": CGRect(x: 20, y: 0, width: 10, height: 10),
    "c": CGRect(x: 40, y: 0, width: 10, height: 10),
]

// MARK: – Tests

/// (1) Subtract drag removes swept ids and their Live partners, leaving unswept
/// selection intact.
@Test func subtractDragRemovesSweptIdsAndPartners() {
    var s = SelectionModel()
    let live = SelectableItem(id: "a", partnerID: "a-live")
    let items: [SelectableItem] = [live, SelectableItem(id: "b"), SelectableItem(id: "c")]
    let frames: [String: CGRect] = [
        "a":      CGRect(x:  0, y: 0, width: 10, height: 10),
        "b":      CGRect(x: 20, y: 0, width: 10, height: 10),
        "c":      CGRect(x: 40, y: 0, width: 10, height: 10),
    ]
    // Pre-select all three (plus Live partner)
    s.selectAll(items)
    s.add(live)   // ensure a-live is in the set
    #expect(s.contains("a") && s.contains("a-live") && s.contains("b") && s.contains("c"))

    // Subtract drag sweeps only "a" and "b"
    s.beginDrag(subtracting: true)
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 25, height: 10), frames: frames, items: items)
    s.endDrag()

    // "a" (+ partner "a-live") and "b" removed; "c" survives
    #expect(!s.contains("a"),      "a should be removed by subtract drag")
    #expect(!s.contains("a-live"), "Live partner of a should be removed too")
    #expect(!s.contains("b"),      "b should be removed by subtract drag")
    #expect(s.contains("c"),       "c was not swept — must remain selected")
}

/// (2) Plain beginDrag() (no argument) still adds — regression guard.
@Test func plainBeginDragStillAdds() {
    var s = SelectionModel()
    let items = makeItems("a", "b", "c")
    s.beginDrag()   // default subtracting: false
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 50, height: 10),
                 frames: sampleFrames, items: items)
    s.endDrag()
    #expect(s.contains("a") && s.contains("b") && s.contains("c"),
            "Default (add) drag must still select all swept cells")
}

/// (3) endDrag resets the mode so a subsequent default drag adds again.
@Test func endDragResetsModeToAdd() {
    var s = SelectionModel()
    let items = makeItems("a", "b", "c")

    // First: subtract drag removes everything swept
    s.selectAll(items)
    s.beginDrag(subtracting: true)
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 50, height: 10),
                 frames: sampleFrames, items: items)
    s.endDrag()
    #expect(s.count == 0, "Subtract drag should have emptied the selection")

    // Second: plain drag must add (mode was reset by endDrag)
    s.beginDrag()
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 50, height: 10),
                 frames: sampleFrames, items: items)
    s.endDrag()
    #expect(s.contains("a") && s.contains("b") && s.contains("c"),
            "After endDrag the next plain drag must add cells again")
}

/// (4) Subtracting an id that was never selected is a harmless no-op.
@Test func subtractUnselectedIdIsNoOp() {
    var s = SelectionModel()
    let items: [SelectableItem] = [SelectableItem(id: "a"), SelectableItem(id: "b")]
    let frames: [String: CGRect] = [
        "a": CGRect(x:  0, y: 0, width: 10, height: 10),
        "b": CGRect(x: 20, y: 0, width: 10, height: 10),
    ]
    // Only "b" is selected; subtract drag sweeps "a" (unselected) and "b"
    s.add(SelectableItem(id: "b"))
    s.beginDrag(subtracting: true)
    s.updateDrag(rect: CGRect(x: 0, y: 0, width: 30, height: 10), frames: frames, items: items)
    s.endDrag()

    // "a" was never selected — no crash, still absent
    #expect(!s.contains("a"), "Subtracting unselected id must be a no-op (still absent)")
    // "b" was selected and swept — should be removed
    #expect(!s.contains("b"), "b was selected and swept — must be removed")
    #expect(s.count == 0)
}
