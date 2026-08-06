import Testing
import Foundation
@testable import OpenPhotoCore

private func item(kind: MediaKind = .photo, w: Int? = 4000, h: Int? = 3000,
                  path: String = "a.jpg") -> TimelineItem {
    TimelineItem(hash: path, kind: kind.rawValue, takenAtMs: 0, pixelWidth: w, pixelHeight: h,
                 latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
                 durationSeconds: nil, livePairHash: nil, favorite: false, rating: 0,
                 caption: nil, tagsJSON: "[]", rotation: 0, vaultID: "v", relPath: path,
                 dirPath: "", size: 1000, driveRelPath: nil)
}

@Test func singlePhotoCopiesPixels() {
    let plan = ClipboardCopyPlan.make(for: [item()])
    #expect(plan.images.count == 1)
    #expect(plan.files.isEmpty)
    #expect(plan.title == "Copy Image")
}

@Test func singleVideoCopiesTheFile() {
    let plan = ClipboardCopyPlan.make(for: [item(kind: .video, path: "a.mov")])
    #expect(plan.images.isEmpty)
    #expect(plan.files.count == 1)
    #expect(plan.title == "Copy File")
}

@Test func severalPhotosCopyAsImages() {
    let plan = ClipboardCopyPlan.make(for: (0..<3).map { item(path: "p\($0).jpg") })
    #expect(plan.images.count == 3)
    #expect(plan.title == "Copy 3 Images")
}

// A mixed selection copies pixels for the photos and file references for the videos, in one write.
@Test func mixedSelectionCopiesBothKinds() {
    let plan = ClipboardCopyPlan.make(for: [item(path: "p0.jpg"), item(path: "p1.jpg"),
                                            item(kind: .video, path: "v.mov")])
    #expect(plan.images.count == 2)
    #expect(plan.files.count == 1)
    #expect(plan.title == "Copy 3 Items")
}

// Past the count cap the whole set falls back to files — the title says so, so the menu never
// promises pixels it won't deliver.
@Test func tooManyPhotosFallBackToFiles() {
    let many = (0...ClipboardCopyBudget.maxImages).map { item(path: "p\($0).jpg") }
    let plan = ClipboardCopyPlan.make(for: many)
    #expect(plan.images.isEmpty)
    #expect(plan.files.count == many.count)
    #expect(plan.title == "Copy \(many.count) Files")
}

// Decoded full-res bytes are the real memory risk (a 100MP photo is ~400MB), so a handful of huge
// photos falls back to files even though the count is small.
@Test func hugePhotosExceedTheByteBudgetAndFallBackToFiles() {
    let huge = (0..<4).map { item(w: 12000, h: 9000, path: "big\($0).dng") }   // ~432 MB each decoded
    let plan = ClipboardCopyPlan.make(for: huge)
    #expect(plan.images.isEmpty)
    #expect(plan.files.count == 4)
}

// Unknown dimensions get a conservative per-photo estimate rather than counting as free.
@Test func unknownDimensionsUseAConservativeEstimate() {
    let unknown = (0..<3).map { item(w: nil, h: nil, path: "u\($0).jpg") }
    #expect(ClipboardCopyPlan.make(for: unknown).images.count == 3)

    let tooMany = (0..<(ClipboardCopyBudget.maxDecodedBytes / ClipboardCopyBudget.assumedDecodedBytes + 1))
        .map { item(w: nil, h: nil, path: "u\($0).jpg") }
    #expect(ClipboardCopyPlan.make(for: tooMany).images.isEmpty)
}

@Test func emptySelectionYieldsAnEmptyPlan() {
    let plan = ClipboardCopyPlan.make(for: [])
    #expect(plan.isEmpty)
}
