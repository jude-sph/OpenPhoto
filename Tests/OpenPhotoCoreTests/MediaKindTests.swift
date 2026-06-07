import Testing
@testable import OpenPhotoCore

@Test func detectsKinds() {
    #expect(MediaKind.of(filename: "IMG_1.HEIC") == .photo)
    #expect(MediaKind.of(filename: "a.jpeg") == .photo)
    #expect(MediaKind.of(filename: "scan.dng") == .photo)
    #expect(MediaKind.of(filename: "shot.PNG") == .photo)
    #expect(MediaKind.of(filename: "clip.mov") == .video)
    #expect(MediaKind.of(filename: "clip.MP4") == .video)
    #expect(MediaKind.of(filename: "notes.txt") == nil)
    #expect(MediaKind.of(filename: ".DS_Store") == nil)
    #expect(MediaKind.of(filename: "IMG_1.heic.xmp") == nil)
}
