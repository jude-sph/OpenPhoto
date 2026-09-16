import Testing
import Foundation
@testable import OpenPhotoCore

private func rec(_ id: String, folders: [String], name: String? = nil) -> TravelRecord {
    TravelRecord(id: id, name: name, folders: folders, startDate: nil, endDate: nil,
                 places: nil, coverHash: nil, createdAtMs: 1, modifiedAtMs: 1)
}

@Test func travelSettingsDefaultWhenAbsentAndRoundTrip() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    #expect(TravelStore.loadSettings(libraryRoot: t.root) == TravelSettings.defaults)
    let s = TravelSettings(travelsFolder: "Travel", autoDiscover: false, hidden: ["Travel/Old"])
    try TravelStore.saveSettings(s, libraryRoot: t.root)
    #expect(TravelStore.loadSettings(libraryRoot: t.root) == s)
}

@Test func travelRecordRoundTripsNullsAndPlaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    var r = rec("id-a", folders: ["Travel/Japan 2026"], name: "Japan")
    r.startDate = "2026-04-03"; r.endDate = nil
    r.places = [TravelPlace(name: "Kyoto", region: "Kyoto", country: "Japan", countryCode: "JP",
                            latitude: 35.02, longitude: 135.75, geonameID: 1857910),
                TravelPlace(name: "Grandma's village")]
    r.coverHash = "sha256:" + String(repeating: "a", count: 64)
    try TravelStore.save(r, libraryRoot: t.root)
    let back = try #require(TravelStore.load(id: "id-a", libraryRoot: t.root))
    #expect(back == r)
    #expect(back.places?[1].isOnMap == false && back.places?[0].isOnMap == true)
    // Null fields are written as JSON null (readers rely on key presence).
    let text = try String(contentsOf: TravelStore.directoryURL(libraryRoot: t.root)
        .appendingPathComponent("id-a.json"), encoding: .utf8)
    #expect(text.contains("\"endDate\" : null"))
    // …including inside a place: a free-text place carries every optional as an explicit null
    // (vault-format-v1 §16.2 shows the full key set).
    #expect(text.contains("\"latitude\" : null"))
    #expect(text.contains("\"geonameID\" : null"))
}

@Test func travelStoreSkipsCorruptFileAndSettings() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try TravelStore.save(rec("good", folders: ["A"]), libraryRoot: t.root)
    let dir = TravelStore.directoryURL(libraryRoot: t.root)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
    let loaded = TravelStore.loadAll(libraryRoot: t.root)
    #expect(loaded.map(\.id) == ["good"])           // corrupt skipped, settings.json never a record
}

@Test func travelStoreLoadAllExcludesSettingsFile() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try TravelStore.saveSettings(TravelSettings(travelsFolder: "T", autoDiscover: true, hidden: []),
                                 libraryRoot: t.root)
    try TravelStore.save(rec("x", folders: ["A"]), libraryRoot: t.root)
    #expect(TravelStore.loadAll(libraryRoot: t.root).map(\.id) == ["x"])
}

@Test func travelStoreDeleteRemovesOne() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    try TravelStore.save(rec("a", folders: ["A"]), libraryRoot: t.root)
    try TravelStore.save(rec("b", folders: ["B"]), libraryRoot: t.root)
    TravelStore.delete(id: "a", libraryRoot: t.root)
    #expect(TravelStore.loadAll(libraryRoot: t.root).map(\.id) == ["b"])
}

@Test func travelStoreSyncToDriveMirrorsSettingsAndPropagatesDeletes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try t.sub("lib"), driveState = try t.sub("drive/.openphoto")
    try TravelStore.saveSettings(TravelSettings(travelsFolder: "Travel", autoDiscover: true, hidden: []),
                                 libraryRoot: lib)
    try TravelStore.save(rec("A", folders: ["Travel/A"]), libraryRoot: lib)
    let driveDir = driveState.appendingPathComponent("travels")
    try FileManager.default.createDirectory(at: driveDir, withIntermediateDirectories: true)
    try Data("orphan".utf8).write(to: driveDir.appendingPathComponent("C.json"))

    try TravelStore.syncToDrive(libraryRoot: lib, driveStateDir: driveState)

    let names = Set((try? FileManager.default.contentsOfDirectory(atPath: driveDir.path)) ?? [])
    #expect(names == ["A.json", "settings.json"])
    #expect(TravelStore.loadSettings(libraryRoot: driveState.deletingLastPathComponent()).travelsFolder == "Travel")
}
