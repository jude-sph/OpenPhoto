import Testing
import Foundation
@testable import OpenPhotoCore

private let H = "sha256:" + String(repeating: "a", count: 64)

private func photoAsset() -> AssetRecord {
    AssetRecord(hash: H, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                caption: nil, tagsJSON: "[]")
}

@Test func xmpRotationRoundTripsAndPreservesOtherFields() throws {
    for deg in [0, 90, 180, 270] {
        let d = SidecarData(rating: 3, favorite: true, caption: "hi", tags: ["a", "b"], rotation: deg)
        let parsed = try XMP.parse(Data(XMP.serialize(d).utf8))
        #expect(parsed.rotation == deg, "rotation \(deg) should round-trip")
        #expect(parsed.rating == 3 && parsed.favorite && parsed.caption == "hi" && parsed.tags == ["a", "b"],
                "other fields survive rotation \(deg)")
    }
}

@Test func sidecarRotationNormalizes() {
    #expect(SidecarData(rating: 0, favorite: false, caption: nil, tags: [], rotation: 450).rotation == 90)
    #expect(SidecarData(rating: 0, favorite: false, caption: nil, tags: [], rotation: -90).rotation == 270)
}

@Test func catalogRotationRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photoAsset()])
    try cat.upsert(instances: [InstanceRecord(hash: H, vaultID: "v1", relPath: "p.jpg",
                                              dirPath: "", size: 10, mtimeMs: 1)])
    #expect(try cat.item(hash: H)?.rotation == 0)         // default
    try cat.setRotation(hash: H, rotation: 270)
    #expect(try cat.item(hash: H)?.rotation == 270)
    try cat.setRotation(hash: H, rotation: 450)            // wraps to 90
    #expect(try cat.item(hash: H)?.rotation == 90)
    // The browse query (what the timeline grid + flatItems use) must also carry the rotation, or a
    // re-opened photo shows the pre-rotation orientation.
    #expect(try cat.timelineItems().first { $0.hash == H }?.rotation == 90)
}
