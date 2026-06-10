import Testing
@testable import OpenPhotoCore

@Test func stripsMatchingSourceBasename() {
    #expect(DrivePathMap.driveToMacRelPath("Pictures/rome2022/a.jpg", sourceBasenames: ["Pictures", "Movies"])
            == "rome2022/a.jpg")
    #expect(DrivePathMap.driveToMacRelPath("Movies/clip.mov", sourceBasenames: ["Pictures", "Movies"])
            == "clip.mov")
}
@Test func leavesNonMatchingPrefixIntact() {
    #expect(DrivePathMap.driveToMacRelPath("Extra/x.jpg", sourceBasenames: ["Pictures"]) == "Extra/x.jpg")
    #expect(DrivePathMap.driveToMacRelPath("a.jpg", sourceBasenames: ["Pictures"]) == "a.jpg")
}
