import Testing
import Foundation
@testable import OpenPhotoCore

private func node(_ path: String, _ children: [FolderNode] = []) -> FolderNode {
    FolderNode(path: path, name: (path as NSString).lastPathComponent, count: 1, children: children)
}
private func rec(_ id: String, _ folders: [String]) -> TravelRecord {
    TravelRecord(id: id, name: nil, folders: folders, startDate: nil, endDate: nil,
                 places: nil, coverHash: nil, createdAtMs: 1, modifiedAtMs: 1)
}
private let tree = [node("Travel", [node("Travel/Japan 2026", [node("Travel/Japan 2026/Kyoto")]),
                                    node("Travel/Peru 2022"), node("Travel/Old")]),
                    node("Family")]
private func settings(_ folder: String? = "Travel", auto: Bool = true, hidden: [String] = []) -> TravelSettings {
    TravelSettings(travelsFolder: folder, autoDiscover: auto, hidden: hidden)
}

@Test func discoversDirectSubfoldersOnly() {
    let defs = TravelResolver.resolve(settings: settings(), records: [], folderTree: tree)
    #expect(defs.map(\.id) == ["folder:Travel/Japan 2026", "folder:Travel/Peru 2022", "folder:Travel/Old"])
    #expect(defs[0].folders == ["Travel/Japan 2026"] && defs[0].isDiscovered)
}

@Test func emptyTravelsFolderMeansVaultRoot() {
    let defs = TravelResolver.resolve(settings: settings(""), records: [], folderTree: tree)
    #expect(defs.map(\.id) == ["folder:Travel", "folder:Family"])
}

@Test func hiddenAndRecordsSupersedeDiscovery() {
    let r = rec("R", ["Travel/Japan 2026/Kyoto"])      // record INSIDE a discovered folder → supersedes
    let defs = TravelResolver.resolve(settings: settings(hidden: ["Travel/Old"]), records: [r], folderTree: tree)
    #expect(defs.map(\.id) == ["R", "folder:Travel/Peru 2022"])
    #expect(defs[0].record == r && !defs[0].isDiscovered)
}

@Test func recordCoveringDiscoveredFolderSupersedesIt() {
    let r = rec("R", ["Travel"])                          // record ABOVE: covers every subfolder
    let defs = TravelResolver.resolve(settings: settings(), records: [r], folderTree: tree)
    #expect(defs.map(\.id) == ["R"])
}

@Test func noTravelsFolderOrAutoOffMeansRecordsOnly() {
    #expect(TravelResolver.resolve(settings: settings(nil), records: [rec("R", ["Family"])], folderTree: tree).map(\.id) == ["R"])
    #expect(TravelResolver.resolve(settings: settings(auto: false), records: [], folderTree: tree).isEmpty)
    #expect(TravelResolver.resolve(settings: settings("Nope"), records: [], folderTree: tree).isEmpty)
}

@Test func normaliseDropsNestedAndDuplicateFolders() {
    #expect(TravelResolver.normalise(folders: ["A/B", "A", "C", "A/B/D", "C"]) == ["A", "C"])
    let r = rec("R", ["Travel/Japan 2026/Kyoto", "Travel/Japan 2026"])
    #expect(TravelResolver.resolve(settings: settings(nil), records: [r], folderTree: tree)[0].folders == ["Travel/Japan 2026"])
}

@Test func summariseDerivesEverythingWhenRecordIsBare() {
    let def = TravelResolver.resolve(settings: settings(), records: [], folderTree: tree)[0]
    let stats = TravelStats(count: 42, minTakenAtMs: 1_775_000_000_000, maxTakenAtMs: 1_776_000_000_000,
                            earliestHash: "sha256:e")
    let kyoto = TravelPlace(name: "Kyoto", countryCode: "JP")
    let s = TravelResolver.summarise(def, stats: stats, detectedPlaces: [kyoto])
    #expect(s.name == "Japan 2026" && s.count == 42 && s.coverHash == "sha256:e" && !s.coverOverridden)
    #expect(s.startDate == TravelResolver.dateString(fromMs: 1_775_000_000_000) && !s.datesOverridden)
    #expect(s.places == [kyoto] && !s.placesOverridden)
}

@Test func summariseHonoursOverridesIncludingEmptyPlacesAndOneDate() {
    var r = rec("R", ["Travel/Peru 2022"])
    r.name = "Peru"; r.startDate = "2022-04-09"; r.places = []; r.coverHash = "sha256:c"
    let def = TravelDefinition(id: "R", source: .record(r), folders: r.folders)
    let stats = TravelStats(count: 3, minTakenAtMs: 1_000_000_000_000, maxTakenAtMs: 1_650_000_000_000,
                            earliestHash: "sha256:e")
    let s = TravelResolver.summarise(def, stats: stats, detectedPlaces: [TravelPlace(name: "Cusco")])
    #expect(s.name == "Peru" && s.startDate == "2022-04-09" && s.datesOverridden)
    #expect(s.endDate == TravelResolver.dateString(fromMs: 1_650_000_000_000))   // other date derived
    #expect(s.places.isEmpty && s.placesOverridden)                              // [] ≠ nil
    #expect(s.coverHash == "sha256:c" && s.coverOverridden)
}

@Test func summariseWithNoPhotosHasNilDatesAndCover() {
    let def = TravelDefinition(id: "R", source: .record(rec("R", ["X"])), folders: ["X"])
    let s = TravelResolver.summarise(def, stats: TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil), detectedPlaces: [])
    #expect(s.startDate == nil && s.endDate == nil && s.coverHash == nil && s.year == nil)
}

@Test func sortedIsNewestFirstThenUndatedThenName() {
    func sum(_ id: String, _ start: String?) -> TravelSummary {
        let def = TravelDefinition(id: id, source: .discovered(id), folders: [id])
        var s = TravelResolver.summarise(def, stats: TravelStats(count: 1, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil), detectedPlaces: [])
        s.startDate = start; return s
    }
    let out = TravelResolver.sorted([sum("b", "2020-01-01"), sum("z", nil), sum("a", "2024-05-05"), sum("c", nil)])
    #expect(out.map(\.id) == ["a", "b", "c", "z"])
}
