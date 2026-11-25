import Testing
@testable import OpenPhotoCore

private func rec(_ id: String, _ folders: [String]) -> TravelRecord {
    TravelRecord(id: id, name: nil, folders: folders, startDate: nil, endDate: nil,
                 places: nil, coverHash: nil, createdAtMs: 1, modifiedAtMs: 1)
}

@Test func rewritePathsFollowsFolderMovesInRecordsAndSettings() {
    let recs = [rec("a", ["Travel/Japan", "Family"]), rec("b", ["Travel/Japan/Kyoto"]), rec("c", ["Other"])]
    let s = TravelSettings(travelsFolder: "Travel", autoDiscover: true, hidden: ["Travel/Old", "Travel/Japan"])
    let out = TravelResolver.rewritePaths(records: recs, settings: s, from: "Travel/Japan", to: "Trips/Japan 2026")
    #expect(out.records[0].folders == ["Trips/Japan 2026", "Family"])
    #expect(out.records[1].folders == ["Trips/Japan 2026/Kyoto"])
    #expect(out.records[2].folders == ["Other"])
    #expect(out.changedRecordIDs == ["a", "b"])
    #expect(out.settings.hidden == ["Travel/Old", "Trips/Japan 2026"])
    let moved = TravelResolver.rewritePaths(records: [], settings: s, from: "Travel", to: "Journeys")
    #expect(moved.settings.travelsFolder == "Journeys" && moved.settings.hidden == ["Journeys/Old", "Journeys/Japan"])
    #expect(TravelResolver.rewritePaths(records: recs, settings: s, from: "Travel/Japanese", to: "X").changedRecordIDs.isEmpty)  // prefix ≠ sibling
}

// Merging folder "A" into "B": a trip spanning both ends up with B once, not twice.
@Test func rewritePathsNormalisesAMergeOntoAnExistingFolder() {
    let out = TravelResolver.rewritePaths(records: [rec("t", ["A", "B"])], settings: .defaults, from: "A", to: "B")
    #expect(out.records[0].folders == ["B"])
    #expect(out.changedRecordIDs == ["t"])
}
