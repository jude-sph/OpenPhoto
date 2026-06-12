import Testing
import Foundation
@testable import OpenPhotoCore

@Test func concurrentEnumerationMatchesSerialSemantics() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    // 40 JPEGs with EXIF dates (reverse order on disk), one video, one non-media file.
    for i in 0..<40 {
        try makeJPEG(at: root.appendingPathComponent("d\(i % 4)/IMG_\(i).jpg").creatingParent(),
                     dateTimeOriginal: String(format: "2022:10:07 14:%02d:%02d", i / 60, i % 60),
                     lat: nil, lon: nil)
    }
    try Data("v".utf8).write(to: root.appendingPathComponent("d0/MOV_1.mp4"))
    // Pin the video's mtime BELOW the photos' EXIF dates so the EXIF-driven sort is observable.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                          ofItemAtPath: root.appendingPathComponent("d0/MOV_1.mp4").path)
    try Data("x".utf8).write(to: root.appendingPathComponent("d0/notes.txt"))

    let src = VolumeSource(rootURL: root, displayName: "export")
    let progress = ProgressBox()
    src.enumerationProgress = { done, total in progress.append((done, total)) }
    let items = try await src.enumerateItems()

    #expect(items.count == 41)                                  // 40 photos + 1 video
    #expect(!items.contains { $0.name == "notes.txt" })
    // EXIF dates won (newest first): IMG_39 has the latest capture time; the
    // epoch-mtime video sorts last.
    #expect(items.first?.name == "IMG_39.jpg")
    #expect(items.last?.name == "MOV_1.mp4")
    // Progress reached completion over the candidate set.
    #expect(progress.values.last?.0 == progress.values.last?.1)
    #expect((progress.values.last?.1 ?? 0) > 0)
    #expect(src.sawXMPSidecars == false)
}

/// Thread-safe accumulator for the @Sendable progress callback.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [(Int, Int)] = []
    func append(_ p: (Int, Int)) { lock.lock(); v.append(p); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return v }
}

@Test func enumerationFlagsAdjacentXMPSidecars() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("export")
    try makeJPEG(at: root.appendingPathComponent("IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    try Data("<x/>".utf8).write(to: root.appendingPathComponent("IMG_1.xmp"))
    let src = VolumeSource(rootURL: root, displayName: "export")
    _ = try await src.enumerateItems()
    #expect(src.sawXMPSidecars == true)
    // The .xmp file itself never enumerates as media.
    #expect(!(try await src.enumerateItems()).contains { $0.name.hasSuffix(".xmp") })
}
