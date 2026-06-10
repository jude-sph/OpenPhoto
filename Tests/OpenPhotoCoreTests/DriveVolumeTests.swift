import Testing
import Foundation
@testable import OpenPhotoCore

@Test func fileSystemVolumeReportsMountedAndFreeSpace() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let vol = FileSystemVolume(rootURL: root)
    #expect(vol.rootURL == root)
    #expect(vol.isMounted == true)
    #expect(try vol.freeSpaceBytes() > 0)
}

@Test func fileSystemVolumeNotMountedWhenMissing() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("openphoto-absent-" + UUID().uuidString)
    let vol = FileSystemVolume(rootURL: missing)
    #expect(vol.isMounted == false)
}

@Test func fileSystemVolumeFreeSpaceThrowsForMissingPath() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("openphoto-absent-" + UUID().uuidString)
    let vol = FileSystemVolume(rootURL: missing)
    #expect(throws: (any Error).self) { try vol.freeSpaceBytes() }
}
