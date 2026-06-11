import Testing
import Foundation
@testable import OpenPhotoCore

private func asset(_ h: String, takenAtMs: Int64, camera: String? = nil, rating: Int = 0,
                   favorite: Bool = false, kind: String = "photo", caption: String? = nil,
                   tags: [String] = []) -> AssetRecord {
    let tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8) ?? "[]") ?? "[]"
    return AssetRecord(hash: h, kind: kind, takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: camera, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: favorite, rating: rating,
        caption: caption, tagsJSON: tagsJSON)
}

/// Seed an asset into the catalog with a local instance so the timeline union returns the row.
/// Uses cat.upsert(instances:) — the real API (not upsertInstances).
private func seedLocal(_ cat: Catalog, _ a: AssetRecord) throws {
    try cat.upsert(assets: [a])
    try cat.upsert(instances: [InstanceRecord(hash: a.hash, vaultID: "v", relPath: a.hash + ".jpg",
        dirPath: "", size: 1, mtimeMs: 1)])
}

private let A = "sha256:" + String(repeating: "a", count: 64)
private let B = "sha256:" + String(repeating: "b", count: 64)

/// Build a SearchFilters from the legacy single-value dimensions these tests exercise.
private func filters(camera: String? = nil, minRating: Int? = nil, favoritesOnly: Bool = false,
                     tags: [String] = [], person: Int64? = nil,
                     place: PlaceFilter? = nil) -> SearchFilters {
    var f = SearchFilters()
    if let camera { f.includeCameras = [camera] }
    f.minRating = minRating
    f.favoritesOnly = favoritesOnly
    f.includeTags = tags
    if let person { f.includePeople = [person] }
    if let place { f.includePlaces = [place] }
    return f
}

@Test func structuredFiltersIsolateAndCombine() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 2000, camera: "Sony", rating: 5, favorite: true,
                             tags: ["rome", "trip"]))
    try seedLocal(cat, asset(B, takenAtMs: 1000, camera: "Canon", rating: 2, tags: ["rome"]))

    #expect(try cat.structuredFilter(filters(camera: "Sony")) == [A])
    #expect(try cat.structuredFilter(filters(minRating: 5)) == [A])
    #expect(try cat.structuredFilter(filters(favoritesOnly: true)) == [A])
    #expect(Set(try cat.structuredFilter(filters(tags: ["rome"]))) == Set([A, B]))
    #expect(try cat.structuredFilter(filters(tags: ["rome", "trip"])) == [A])   // AND semantics
    #expect(try cat.structuredFilter(filters(camera: "Sony", minRating: 5)) == [A])
}

@Test func itemsForHashesPreservesOrder() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 1000))
    try seedLocal(cat, asset(B, takenAtMs: 2000))
    let items = try cat.items(forHashes: [B, A], preservingOrder: true)
    #expect(items.map(\.hash) == [B, A])     // honors the given order, not takenAtMs
}

@Test func personFilterNarrowsToThatPersonsPhotos() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    // Seed two assets: A has Alice's face; B does not.
    try seedLocal(cat, asset(A, takenAtMs: 2000))
    try seedLocal(cat, asset(B, takenAtMs: 1000))
    let f = try cat.insertFaces([FaceRow(id: nil, hash: A,
        rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), embedding: [1, 0],
        confidence: 0.9, source: "auto", personID: nil)])
    let alice = try cat.createPerson(name: "Alice")
    try cat.assignFaces(f, to: alice)
    // Only A has Alice's face.
    #expect(try cat.structuredFilter(filters(person: alice)) == [A])
    // Composing person filter with favoritesOnly: A is not a favorite → empty.
    #expect(try cat.structuredFilter(filters(favoritesOnly: true, person: alice)).isEmpty)
}

@Test func distinctCamerasAndTags() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 1, camera: "Sony", tags: ["rome", "trip"]))
    try seedLocal(cat, asset(B, takenAtMs: 2, camera: "Canon", tags: ["rome"]))
    #expect(Set(try cat.distinctCameras()) == Set(["Sony", "Canon"]))
    #expect(Set(try cat.distinctTags()) == Set(["rome", "trip"]))
}

@Test func placeFilterNarrowsAndComposes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try seedLocal(cat, asset(A, takenAtMs: 2000))
    try seedLocal(cat, asset(B, takenAtMs: 1000))
    try cat.upsertGeocode(GeocodeRow(hash: A, city: "Taipei", region: "Taipei",
                                     country: "Taiwan", countryCode: "TW"))
    try cat.upsertGeocode(GeocodeRow(hash: B, city: "Tokyo", region: "Tokyo",
                                     country: "Japan", countryCode: "JP"))
    // Country facet: only A (Taiwan).
    #expect(try cat.structuredFilter(filters(place: .country("TW"))) == [A])
    // City facet: only B (Tokyo).
    #expect(try cat.structuredFilter(filters(place: .city(countryCode: "JP", city: "Tokyo"))) == [B])
    // Composes with another filter: A is not a favorite → empty.
    #expect(try cat.structuredFilter(filters(favoritesOnly: true, place: .country("TW"))).isEmpty)
}

// MARK: Power-user structuredFilter facets

/// Seed builder: accumulate assets + ONE local instance each (so they appear in the union),
/// then persist. Faces/geocode/ocr are added per-hash afterwards (additive APIs).
private final class PufSeed {
    var assets: [AssetRecord] = []
    var instances: [InstanceRecord] = []
    func add(_ hash: String, dir: String = "", taken: Int64 = 1, camera: String? = nil,
             rating: Int = 0, favorite: Bool = false, kind: String = "photo",
             livePair: String? = nil, tags: [String] = []) {
        let tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
        assets.append(AssetRecord(hash: hash, kind: kind, takenAtMs: taken, pixelWidth: nil,
            pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: camera, lensModel: nil,
            durationSeconds: nil, livePairHash: livePair, isLivePairedVideo: false,
            favorite: favorite, rating: rating, caption: nil, tagsJSON: tagsJSON))
        let rel = dir.isEmpty ? "\(hash).jpg" : "\(dir)/\(hash).jpg"
        instances.append(InstanceRecord(hash: hash, vaultID: "v", relPath: rel, dirPath: dir,
                                        size: 1, mtimeMs: taken))
    }
    func commit(_ cat: Catalog) throws {
        try cat.upsert(assets: assets)
        try cat.replaceInstances(inVault: "v", with: instances)
    }
}
private func pufHash(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func filterMultiPersonIsAndExcludeIsNoneOf() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed(); s.add(pufHash("a")); s.add(pufHash("b")); s.add(pufHash("c")); try s.commit(cat)
    let sarah = try cat.createPerson(name: "Sarah")
    let tom = try cat.createPerson(name: "Tom")
    func face(_ hash: String, _ pid: Int64) -> FaceRow {
        FaceRow(id: nil, hash: hash, rect: .zero, embedding: [], confidence: 1, source: "confirmed", personID: pid)
    }
    _ = try cat.insertFaces([face(pufHash("a"), sarah), face(pufHash("a"), tom),
                             face(pufHash("b"), sarah), face(pufHash("c"), tom)])
    var both = SearchFilters(); both.includePeople = [sarah, tom]
    #expect(Set(try cat.structuredFilter(both)) == [pufHash("a")])
    var either = SearchFilters(); either.includePeople = [sarah]
    #expect(Set(try cat.structuredFilter(either)) == [pufHash("a"), pufHash("b")])
    var notTom = SearchFilters(); notTom.includePeople = [sarah]; notTom.excludePeople = [tom]
    #expect(Set(try cat.structuredFilter(notTom)) == [pufHash("b")])
}

@Test func filterPeoplePresence() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed(); s.add(pufHash("a")); s.add(pufHash("b")); try s.commit(cat)
    let p = try cat.createPerson(name: "X")
    _ = try cat.insertFaces([FaceRow(id: nil, hash: pufHash("a"), rect: .zero, embedding: [],
                                     confidence: 1, source: "confirmed", personID: p)])
    var has = SearchFilters(); has.peoplePresence = .has
    #expect(Set(try cat.structuredFilter(has)) == [pufHash("a")])
    var without = SearchFilters(); without.peoplePresence = .without
    #expect(Set(try cat.structuredFilter(without)) == [pufHash("b")])
}

@Test func filterFoldersRecursiveExactExcludeAndSiblingSafety() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed()
    s.add(pufHash("a"), dir: "canada23"); s.add(pufHash("b"), dir: "canada23/day1")
    s.add(pufHash("c"), dir: "canada23x"); s.add(pufHash("d"), dir: "rome")
    try s.commit(cat)
    var rec = SearchFilters(); rec.includeFolders = ["canada23"]
    #expect(Set(try cat.structuredFilter(rec)) == [pufHash("a"), pufHash("b")])
    var exact = SearchFilters(); exact.includeFolders = ["canada23"]; exact.foldersRecursive = false
    #expect(Set(try cat.structuredFilter(exact)) == [pufHash("a")])
    var excl = SearchFilters(); excl.excludeFolders = ["canada23"]
    #expect(Set(try cat.structuredFilter(excl)) == [pufHash("c"), pufHash("d")])
}

@Test func filterFolderMatchesDriveOnlyAsset() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [AssetRecord(hash: pufHash("a"), kind: "photo", takenAtMs: 1, pixelWidth: nil,
        pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")])
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: pufHash("a"), relPath: "trip/x.jpg", dirPath: "trip",
                           size: 1, driveRelPath: "Drive/trip/x.jpg")])
    var f = SearchFilters(); f.includeFolders = ["trip"]
    #expect(Set(try cat.structuredFilter(f)) == [pufHash("a")])
}

@Test func filterTagsIncludeAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed()
    s.add(pufHash("a"), tags: ["beach", "summer"]); s.add(pufHash("b"), tags: ["beach"]); s.add(pufHash("c"), tags: ["winter"])
    try s.commit(cat)
    var andTags = SearchFilters(); andTags.includeTags = ["beach", "summer"]
    #expect(Set(try cat.structuredFilter(andTags)) == [pufHash("a")])
    var excl = SearchFilters(); excl.includeTags = ["beach"]; excl.excludeTags = ["summer"]
    #expect(Set(try cat.structuredFilter(excl)) == [pufHash("b")])
}

@Test func filterPlacesIncludeOrAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed(); s.add(pufHash("a")); s.add(pufHash("b")); s.add(pufHash("c")); try s.commit(cat)
    try cat.upsertGeocode(GeocodeRow(hash: pufHash("a"), city: "Taipei", region: "", country: "Taiwan", countryCode: "TW"))
    try cat.upsertGeocode(GeocodeRow(hash: pufHash("b"), city: "Rome", region: "", country: "Italy", countryCode: "IT"))
    try cat.upsertGeocode(GeocodeRow(hash: pufHash("c"), city: "Osaka", region: "", country: "Japan", countryCode: "JP"))
    var incl = SearchFilters()
    incl.includePlaces = [.city(countryCode: "TW", city: "Taipei"), .country("IT")]
    #expect(Set(try cat.structuredFilter(incl)) == [pufHash("a"), pufHash("b")])
    var excl = SearchFilters(); excl.excludePlaces = [.country("JP")]
    #expect(Set(try cat.structuredFilter(excl)) == [pufHash("a"), pufHash("b")])
}

@Test func filterCamerasIncludeOrAndExclude() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed()
    s.add(pufHash("a"), camera: "X100"); s.add(pufHash("b"), camera: "iPhone"); s.add(pufHash("c"))
    try s.commit(cat)
    var incl = SearchFilters(); incl.includeCameras = ["X100", "iPhone"]
    #expect(Set(try cat.structuredFilter(incl)) == [pufHash("a"), pufHash("b")])
    var excl = SearchFilters(); excl.excludeCameras = ["iPhone"]
    #expect(Set(try cat.structuredFilter(excl)) == [pufHash("a"), pufHash("c")])
}

@Test func filterKind() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed()
    s.add(pufHash("a"), kind: "photo"); s.add(pufHash("b"), kind: "video")
    s.add(pufHash("c"), kind: "photo", livePair: pufHash("z"))
    try s.commit(cat)
    var photo = SearchFilters(); photo.kind = .photo
    #expect(Set(try cat.structuredFilter(photo)) == [pufHash("a")])
    var video = SearchFilters(); video.kind = .video
    #expect(Set(try cat.structuredFilter(video)) == [pufHash("b")])
    var live = SearchFilters(); live.kind = .live
    #expect(Set(try cat.structuredFilter(live)) == [pufHash("c")])
}

@Test func filterHasText() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed(); s.add(pufHash("a")); s.add(pufHash("b")); try s.commit(cat)
    try cat.upsertOCR(hash: pufHash("a"), text: "SALE 50% OFF")
    try cat.upsertOCR(hash: pufHash("b"), text: "")
    var f = SearchFilters(); f.hasText = true
    #expect(Set(try cat.structuredFilter(f)) == [pufHash("a")])
}

@Test func filterComposesMultipleFacets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let s = PufSeed()
    s.add(pufHash("a"), dir: "canada23", kind: "photo", tags: ["trip"])
    s.add(pufHash("b"), dir: "canada23", kind: "video", tags: ["trip"])
    s.add(pufHash("c"), dir: "rome", kind: "photo", tags: ["trip"])
    try s.commit(cat)
    let sarah = try cat.createPerson(name: "Sarah")
    _ = try cat.insertFaces([FaceRow(id: nil, hash: pufHash("a"), rect: .zero, embedding: [],
        confidence: 1, source: "confirmed", personID: sarah),
        FaceRow(id: nil, hash: pufHash("b"), rect: .zero, embedding: [], confidence: 1,
                source: "confirmed", personID: sarah)])
    var f = SearchFilters()
    f.includePeople = [sarah]; f.includeFolders = ["canada23"]; f.kind = .photo; f.includeTags = ["trip"]
    #expect(Set(try cat.structuredFilter(f)) == [pufHash("a")])
}
