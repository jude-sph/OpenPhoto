import Testing
import Foundation
@testable import OpenPhotoCore

@Test func tempFolderClassifiesAsFolder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = try t.sub("drive")
    #expect(DriveKind.of(path: dir.path) == .folder)   // system temp lives on the internal volume
    #expect(DriveKind.of(path: dir.path).isRealVolume == false)
}

@Test func missingPathClassifiesAsUnknown() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("openphoto-absent-" + UUID().uuidString)
    #expect(DriveKind.of(path: missing.path) == .unknown)
}
