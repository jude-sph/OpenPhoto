import Testing
@testable import OpenPhotoCore

@Test func gatherQueriesPartitionLocalAndDriveOnly() async throws {
    let h = try StorageTestHarness.make()
    let localItems = try h.makeLocalBackedUp(count: 2, sizeEach: 1000)   // present on Mac + drive
    let driveOnly = try h.makeDriveOnly(count: 3, sizeEach: 1000)        // drive only

    let presence = Set(localItems.map(\.hash))   // the 2 local items are "backed up"
    let evictable = try h.lib.allEvictableLocal(canonicalPresence: presence)
    let onlyOnDrive = try h.lib.allDriveOnly()

    #expect(Set(evictable.map(\.hash)) == Set(localItems.map(\.hash)))
    #expect(Set(onlyOnDrive.map(\.hash)) == Set(driveOnly.map(\.hash)))
}
