import Testing
import Foundation
@testable import OpenPhotoCore

private func item(_ id: String, name: String, kind: MediaKind,
                  taken: TimeInterval) -> ImportItem {
    ImportItem(id: id, name: name, byteSize: 100, takenAt: Date(timeIntervalSince1970: taken),
               kind: kind, livePartnerID: nil)
}

@Test func pairsLiveItemsByBasenameAndTime() {
    let paired = pairLiveItems([
        item("1", name: "IMG_1.HEIC", kind: .photo, taken: 100),
        item("2", name: "IMG_1.MOV", kind: .video, taken: 101),
        item("3", name: "IMG_2.HEIC", kind: .photo, taken: 200),
        item("4", name: "CLIP.MOV", kind: .video, taken: 300),
    ])
    let p1 = paired.first { $0.id == "1" }!
    let v1 = paired.first { $0.id == "2" }!
    #expect(p1.livePartnerID == "2")
    #expect(v1.livePartnerID == "1")
    #expect(paired.first { $0.id == "3" }!.livePartnerID == nil)
    #expect(paired.first { $0.id == "4" }!.livePartnerID == nil)
}

@Test func fakeSourceRoundTrips() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let fake = FakeSource(sourceKey: "fake-1", items: [
        (item("a", name: "A.JPG", kind: .photo, taken: 10), Data("aaa".utf8)),
    ])
    let listed = try await fake.enumerateItems()
    #expect(listed.count == 1 && listed[0].name == "A.JPG")
    let dest = t.root.appendingPathComponent("a.jpg")
    try await fake.fetch(listed[0], to: dest)
    #expect(try Data(contentsOf: dest) == Data("aaa".utf8))
    let results = try await fake.delete([listed[0]])
    #expect(results == [DeleteResult(itemID: "a", error: nil)])
    #expect(fake.deletedIDs == ["a"])
}

// Same basename in DIFFERENT source folders is not a Live Photo (e.g. 100APPLE/IMG_0001.HEIC and
// 101APPLE/IMG_0001.MOV after the counter wraps, or two trips' exports): pair only within a folder.
@Test func pairsLiveItemsOnlyWithinTheSameFolder() {
    let paired = pairLiveItems([
        item("DCIM/100APPLE/IMG_0001.HEIC", name: "IMG_0001.HEIC", kind: .photo, taken: 100),
        item("DCIM/101APPLE/IMG_0001.MOV", name: "IMG_0001.MOV", kind: .video, taken: 500),
        item("DCIM/101APPLE/IMG_0002.HEIC", name: "IMG_0002.HEIC", kind: .photo, taken: 600),
        item("DCIM/101APPLE/IMG_0002.MOV", name: "IMG_0002.MOV", kind: .video, taken: 601),
        item("DCIM/102APPLE/IMG_0002.MOV", name: "IMG_0002.MOV", kind: .video, taken: 900),
    ])
    func partner(_ id: String) -> String? { paired.first { $0.id == id }!.livePartnerID }
    #expect(partner("DCIM/100APPLE/IMG_0001.HEIC") == nil)
    #expect(partner("DCIM/101APPLE/IMG_0001.MOV") == nil)
    #expect(partner("DCIM/101APPLE/IMG_0002.HEIC") == "DCIM/101APPLE/IMG_0002.MOV")
    #expect(partner("DCIM/101APPLE/IMG_0002.MOV") == "DCIM/101APPLE/IMG_0002.HEIC")
    #expect(partner("DCIM/102APPLE/IMG_0002.MOV") == nil)
}

// A pairing the source already established (Photos library: still ↔ its own paired video) is kept.
@Test func pairLiveItemsKeepsSourceProvidedPairs() {
    var a = item("p:1:original", name: "IMG_1.HEIC", kind: .photo, taken: 1); a.livePartnerID = "p:1:video"
    var av = item("p:1:video", name: "IMG_1.mov", kind: .video, taken: 1); av.livePartnerID = "p:1:original"
    let b = item("p:2:original", name: "IMG_1.HEIC", kind: .photo, taken: 2)      // same name, not Live
    let paired = pairLiveItems([a, av, b])
    #expect(paired.first { $0.id == "p:1:original" }!.livePartnerID == "p:1:video")
    #expect(paired.first { $0.id == "p:1:video" }!.livePartnerID == "p:1:original")
    #expect(paired.first { $0.id == "p:2:original" }!.livePartnerID == nil)
}
