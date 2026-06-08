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
