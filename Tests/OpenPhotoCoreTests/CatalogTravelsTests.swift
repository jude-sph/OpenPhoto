import Testing
import Foundation
@testable import OpenPhotoCore

private func h(_ n: Int) -> String { "sha256:" + String(format: "%064d", n) }
private func asset(_ n: Int, taken: Int64) -> AssetRecord {
    AssetRecord(hash: h(n), kind: "photo", takenAtMs: taken, pixelWidth: nil, pixelHeight: nil,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
}
private func inst(_ n: Int, _ rel: String) -> InstanceRecord {
    InstanceRecord(hash: h(n), vaultID: "mac", relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 1, mtimeMs: 0)
}

/// Japan trip: Kyoto (1,2) + Osaka (3); a sibling "Japan 2026x" (4) that a LIKE would wrongly match;
/// Peru (5) with photo 5 also copied into Kyoto (same content in two folders).
private func seeded() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "mac", role: "local", rootPath: "/p")
    try cat.upsert(assets: [asset(1, taken: 300), asset(2, taken: 100), asset(3, taken: 200),
                            asset(4, taken: 50), asset(5, taken: 900)])
    try cat.replaceInstances(inVault: "mac", with: [
        inst(1, "Travel/Japan 2026/Kyoto/a.jpg"), inst(2, "Travel/Japan 2026/Kyoto/b.jpg"),
        inst(3, "Travel/Japan 2026/Osaka/c.jpg"), inst(4, "Travel/Japan 2026x/d.jpg"),
        inst(5, "Travel/Peru 2022/e.jpg"), inst(5, "Travel/Japan 2026/Kyoto/e-copy.jpg"),
    ])
    try cat.upsertGeocode(GeocodeRow(hash: h(1), city: "Kyoto", region: "Kyoto", country: "Japan", countryCode: "JP"))
    try cat.upsertGeocode(GeocodeRow(hash: h(2), city: "Kyoto", region: "Kyoto", country: "Japan", countryCode: "JP"))
    try cat.upsertGeocode(GeocodeRow(hash: h(3), city: "Osaka", region: "Osaka", country: "Japan", countryCode: "JP"))
    try cat.upsertGeocode(GeocodeRow(hash: h(5), city: "Cusco", region: "Cusco", country: "Peru", countryCode: "PE"))
    return (t, cat)
}

@Test func travelStatsSpansSubfoldersNotSiblingPrefix() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let s = try cat.travelStats(dirPaths: ["Travel/Japan 2026"])
    #expect(s.count == 4)                                   // 1,2,3 + the copy of 5; NOT 4 ("…2026x")
    #expect(s.minTakenAtMs == 100 && s.maxTakenAtMs == 900)
    #expect(s.earliestHash == h(2))
}

@Test func travelStatsUnionsFoldersWithoutDoubleCounting() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let s = try cat.travelStats(dirPaths: ["Travel/Japan 2026/Kyoto", "Travel/Peru 2022"])
    #expect(s.count == 4)                                   // 1,2, copy-of-5 in Kyoto, 5 in Peru (per instance)
    #expect(try cat.travelStats(dirPaths: ["Nowhere"]) == TravelStats(count: 0, minTakenAtMs: nil, maxTakenAtMs: nil, earliestHash: nil))
    #expect(try cat.travelStats(dirPaths: []).count == 0)
}

@Test func travelPlacesOrderedByPhotoCount() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let p = try cat.travelPlaces(dirPaths: ["Travel/Japan 2026"])
    #expect(p.map(\.city) == ["Kyoto", "Osaka", "Cusco"])   // Kyoto 2, Osaka 1, Cusco 1 (the copy)
    #expect(p[0].count == 2 && p[0].region == "Kyoto" && p[0].countryCode == "JP")
}

@Test func travelQueriesHonourLockedGate() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["Travel/Japan 2026/Osaka"])
    cat.revealLocked = false
    #expect(try cat.travelStats(dirPaths: ["Travel/Japan 2026"]).count == 3)
    #expect(try cat.travelPlaces(dirPaths: ["Travel/Japan 2026"]).map(\.city) == ["Kyoto", "Cusco"])
    cat.revealLocked = true
    #expect(try cat.travelStats(dirPaths: ["Travel/Japan 2026"]).count == 4)
}

@Test func travelItemsAscendingAndDeduplicated() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let items = try cat.travelItems(dirPaths: ["Travel/Japan 2026", "Travel/Japan 2026/Kyoto"])
    #expect(items.map(\.hash) == [h(2), h(3), h(1), h(5)])  // taken 100, 200, 300, 900; Kyoto listed twice → once
}
