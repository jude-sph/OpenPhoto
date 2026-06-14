import Testing
import Foundation
@testable import OpenPhotoCore

@Test func lockedFolderStoreRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let paths = ["/A", "/B/sub"]
    try LockedFolderStore.save(paths, libraryRoot: t.root)
    let loaded = LockedFolderStore.load(libraryRoot: t.root)
    #expect(loaded == paths)
}

@Test func lockedFolderStoreEmptyOnFreshDir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let loaded = LockedFolderStore.load(libraryRoot: t.root)
    #expect(loaded == [])
}

@Test func lockedFolderStoreOverwriteReplaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try LockedFolderStore.save(["/first"], libraryRoot: t.root)
    try LockedFolderStore.save(["/second", "/third"], libraryRoot: t.root)
    let loaded = LockedFolderStore.load(libraryRoot: t.root)
    #expect(loaded == ["/second", "/third"])
}

@Test func lockedFolderStoreWritesToDotOpenphotoSubdir() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try LockedFolderStore.save(["/x"], libraryRoot: t.root)
    let expected = t.root
        .appendingPathComponent(".openphoto")
        .appendingPathComponent("locked-folders.json")
    #expect(FileManager.default.fileExists(atPath: expected.path))
}

@Test func lockedFolderStoreEmptyArrayRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try LockedFolderStore.save([], libraryRoot: t.root)
    let loaded = LockedFolderStore.load(libraryRoot: t.root)
    #expect(loaded == [])
}
