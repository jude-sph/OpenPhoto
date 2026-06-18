import Testing
import Foundation
import CoreGraphics
import GRDB
@testable import OpenPhotoCore

// MARK: - Helpers

private func asset(_ h: String, takenAtMs: Int64 = 1) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: takenAtMs, pixelWidth: nil, pixelHeight: nil,
                latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                caption: nil, tagsJSON: "[]")
}

private func inst(_ h: String, _ rel: String, vaultID: String = "mac") -> InstanceRecord {
    InstanceRecord(hash: h, vaultID: vaultID, relPath: rel,
                   dirPath: (rel as NSString).deletingLastPathComponent, size: 10, mtimeMs: 1)
}

private let HA = "sha256:" + String(repeating: "a", count: 64)   // in /A
private let HB = "sha256:" + String(repeating: "b", count: 64)   // in /A/sub
private let HC = "sha256:" + String(repeating: "c", count: 64)   // in /B (unlocked)

/// Seed a fresh catalog with three assets:
///   HA → /A/photo.jpg        (will be locked with /A)
///   HB → /A/sub/photo.jpg   (will be locked via /A/*)
///   HC → /B/photo.jpg        (never locked)
private func seeded() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [asset(HA), asset(HB), asset(HC)])
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"),
        inst(HB, "A/sub/photo.jpg"),
        inst(HC, "B/photo.jpg"),
    ])
    return (t, cat)
}

// MARK: - applyLockedFolders

@Test func applyLockedFoldersMarksExactAndNestedDirPaths() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }

    try cat.applyLockedFolders(["A"])

    // Read locked flags directly from the DB
    let rows = try cat.dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT dirPath, locked FROM instances ORDER BY relPath")
    }
    var byDir: [String: Int] = [:]
    for row in rows {
        let dir: String = row["dirPath"]
        let locked: Int = row["locked"]
        byDir[dir] = locked
    }
    #expect(byDir["A"] == 1,     "direct match of the locked folder")
    #expect(byDir["A/sub"] == 1, "nested subfolder also locked via GLOB")
    #expect(byDir["B"] == 0,     "/B is not under A and must remain unlocked")
}

@Test func applyLockedFoldersEmptyListClearsAllLocks() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }

    try cat.applyLockedFolders(["A"])
    try cat.applyLockedFolders([])   // clear

    let locked = try cat.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM instances WHERE locked = 1") ?? 0
    }
    #expect(locked == 0, "applyLockedFolders([]) must clear all locks")
}

@Test func applyLockedFoldersIsIdempotent() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }

    try cat.applyLockedFolders(["A"])
    try cat.applyLockedFolders(["A"])   // second call — must not double-count

    let locked = try cat.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM instances WHERE locked = 1") ?? 0
    }
    #expect(locked == 2, "exactly the two instances under /A are locked")
}

@Test func replaceInstancesPreservesLockedAcrossRescan() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    // Simulate a re-scan: the scanner replaces all instances wholesale, and InstanceRecord carries
    // no `locked` field — so without preservation this would reset every lock to 0 and expose the
    // folder. The lock MUST survive a rescan with no explicit re-apply.
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"),
        inst(HB, "A/sub/photo.jpg"),
        inst(HC, "B/photo.jpg"),
    ])
    #expect(try cat.items(inDir: "A").isEmpty, "locked folder must stay hidden after a rescan")
    #expect(try cat.items(inDir: "A/sub").isEmpty, "locked subfolder must stay hidden after a rescan")
    #expect(try cat.items(inDir: "B").count == 1, "unlocked folder still visible after a rescan")

    // A new file appearing in the already-locked folder inherits the lock across the replace.
    let HN = "sha256:" + String(repeating: "f", count: 64)
    try cat.upsert(assets: [asset(HN)])
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"), inst(HB, "A/sub/photo.jpg"),
        inst(HC, "B/photo.jpg"), inst(HN, "A/new.jpg"),
    ])
    let lockedNew = try cat.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT locked FROM instances WHERE relPath = 'A/new.jpg'") ?? 0
    }
    #expect(lockedNew == 1, "a new file in an already-locked folder inherits the lock across rescan")
}

// MARK: - revealLocked default / toggle

@Test func revealLockedDefaultsToFalse() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    #expect(cat.revealLocked == false)
}

@Test func revealLockedToggleChangesValue() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    cat.revealLocked = true
    #expect(cat.revealLocked == true)
    cat.revealLocked = false
    #expect(cat.revealLocked == false)
}

// MARK: - timelineItems

@Test func timelineItemsHidesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    let hashes = try cat.timelineItems().map(\.hash)
    #expect(!hashes.contains(HA), "HA is locked and must not appear")
    #expect(!hashes.contains(HB), "HB is locked (nested) and must not appear")
    #expect(hashes.contains(HC), "/B/photo.jpg is unlocked and must appear")
}

@Test func timelineItemsShowsAllWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true

    let hashes = Set(try cat.timelineItems().map(\.hash))
    #expect(hashes == [HA, HB, HC], "all rows must appear when revealLocked = true")
}

@Test func timelineItemsVideoOnlyAndLockedFilterCompose() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    // Add a video in /A (should be hidden when locked) and a video in /B (visible)
    let HV = "sha256:" + String(repeating: "v", count: 64)
    let HW = "sha256:" + String(repeating: "w", count: 64)
    let vid = { (h: String) -> AssetRecord in
        AssetRecord(hash: h, kind: "video", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
                    latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
                    livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
                    caption: nil, tagsJSON: "[]")
    }
    try cat.upsert(assets: [vid(HV), vid(HW)])
    try cat.upsert(instances: [inst(HV, "A/clip.mov"), inst(HW, "B/clip.mov")])
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    let hashes = Set(try cat.timelineItems(videoOnly: true).map(\.hash))
    #expect(!hashes.contains(HV), "video in locked folder must be hidden")
    #expect(hashes.contains(HW), "video in unlocked folder must appear")
}

// MARK: - items(inDir:)

@Test func itemsInDirHidesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    let inA = try cat.items(inDir: "A")
    #expect(inA.isEmpty, "locked folder must return no items when hidden")

    let inSub = try cat.items(inDir: "A/sub")
    #expect(inSub.isEmpty, "locked subfolder must return no items when hidden")

    let inB = try cat.items(inDir: "B")
    #expect(inB.count == 1 && inB[0].hash == HC, "unlocked folder still returns its item")
}

@Test func itemsInDirShowsAllWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true

    #expect(try cat.items(inDir: "A").count == 1)
    #expect(try cat.items(inDir: "A/sub").count == 1)
}

// MARK: - item(hash:)

@Test func itemHashHidesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    #expect(try cat.item(hash: HA) == nil, "locked item must not resolve while hidden")
    #expect(try cat.item(hash: HB) == nil, "locked nested item must not resolve while hidden")
    #expect(try cat.item(hash: HC) != nil, "unlocked item must still resolve")
}

@Test func itemHashResolvesWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true

    #expect(try cat.item(hash: HA) != nil)
    #expect(try cat.item(hash: HB) != nil)
}

// MARK: - folderCounts

@Test func folderCountsExcludesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    let counts = try cat.folderCounts()
    #expect(counts["A"] == nil || counts["A"] == 0, "locked folder A must have count 0")
    #expect(counts["A/sub"] == nil || counts["A/sub"] == 0, "locked subfolder must have count 0")
    #expect(counts["B"] == 1, "unlocked folder B must still be counted")
}

@Test func folderCountsIncludesLockedWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true

    let counts = try cat.folderCounts()
    #expect((counts["A"] ?? 0) == 1, "A's count must appear when revealed")
    #expect((counts["A/sub"] ?? 0) == 1, "A/sub's count must appear when revealed")
    #expect((counts["B"] ?? 0) == 1)
}

// MARK: - duplicateInstanceGroups

@Test func duplicateGroupsExcludesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    // Add a duplicate pair in /A (both locked) and a pair in /B (unlocked)
    let HD = "sha256:" + String(repeating: "d", count: 64)
    try cat.upsert(assets: [asset(HC)])   // HC already exists; add another copy in B
    // HC is unique in B; for a real duplicate add a second copy
    let HC2 = "sha256:" + String(repeating: "e", count: 64)
    try cat.upsert(assets: [asset(HD), asset(HC2)])
    // Duplicate pair in /A (both will be locked)
    try cat.upsert(instances: [inst(HD, "A/dup1.jpg"), inst(HD, "A/dup2.jpg")])
    // Duplicate pair in /B (unlocked)
    try cat.upsert(instances: [inst(HC2, "B/dup1.jpg"), inst(HC2, "B/dup2.jpg")])

    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false

    let groups = try cat.duplicateInstanceGroups(scope: .withinFolder)
    // Only the /B pair should appear; /A pair is locked
    let allIDs = groups.flatMap { $0 }
    #expect(!allIDs.contains(where: { $0.hasPrefix("mac|A/") }),
            "duplicate instances in locked folders must be hidden")
    #expect(allIDs.contains(where: { $0.hasPrefix("mac|B/") }),
            "duplicate instances in unlocked folders must appear")
}

@Test func duplicateGroupsIncludesLockedWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let HD = "sha256:" + String(repeating: "d", count: 64)
    try cat.upsert(assets: [asset(HD)])
    try cat.upsert(instances: [inst(HD, "A/dup1.jpg"), inst(HD, "A/dup2.jpg")])

    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true

    let groups = try cat.duplicateInstanceGroups(scope: .withinFolder)
    let allIDs = groups.flatMap { $0 }
    #expect(allIDs.contains(where: { $0.hasPrefix("mac|A/") }),
            "locked duplicates must appear when revealLocked = true")
}

// MARK: - knownSizeDateKeys (must be UNAFFECTED by lock state)

@Test func knownSizeDateKeysUnaffectedByLockState() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let keysUnlocked = try cat.knownSizeDateKeys()

    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false
    let keysLocked = try cat.knownSizeDateKeys()

    // Import dedup must still see locked photos — size+date keys must be identical
    #expect(keysUnlocked == keysLocked,
            "knownSizeDateKeys must be identical regardless of lock state (import dedup uses it)")

    cat.revealLocked = true
    let keysRevealed = try cat.knownSizeDateKeys()
    #expect(keysUnlocked == keysRevealed)
}

// MARK: - librarySize

@Test func librarySizeExcludesLockedWhenNotRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let (countAll, _) = try cat.librarySize()

    try cat.applyLockedFolders(["A"])
    cat.revealLocked = false
    let (countLocked, _) = try cat.librarySize()

    #expect(countLocked == countAll - 2,
            "librarySize must exclude the 2 locked instances when not revealed")
}

@Test func librarySizeIncludesLockedWhenRevealed() throws {
    let (t, cat) = try seeded(); defer { t.cleanup() }
    let (countAll, _) = try cat.librarySize()

    try cat.applyLockedFolders(["A"])
    cat.revealLocked = true
    let (countRevealed, _) = try cat.librarySize()

    #expect(countRevealed == countAll, "librarySize must include locked rows when revealLocked = true")
}

// MARK: - LF2: faces / map / search filters

// A minimal FaceRow padded to 512 dimensions so the `dim = 512` clusterable filter
// in `unassignedFacesWithEmbeddings` keeps these synthetic faces.
private func lockedFace(_ hash: String, vec: [Float] = [1, 0]) -> FaceRow {
    var v = vec
    if v.count < FaceEmbedder.dimension {
        v += Array(repeating: 0, count: FaceEmbedder.dimension - v.count)
    }
    return FaceRow(id: nil, hash: hash,
                   rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                   embedding: v, confidence: 0.9, source: "auto",
                   personID: nil, quality: 1)
}

/// Seed for LF2 tests: HA in locked folder /A, HC in unlocked /B.
/// Both photos have a face, OCR text, and GPS coords.
private func seededLF2() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))

    // HA → locked /A, HC → unlocked /B (both with GPS for map test)
    let assetA = AssetRecord(hash: HA, kind: "photo", takenAtMs: 2,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: 51.5074, longitude: -0.1278,
                             cameraModel: nil, lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    let assetC = AssetRecord(hash: HC, kind: "photo", takenAtMs: 1,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: 48.8566, longitude: 2.3522,
                             cameraModel: nil, lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [assetA, assetC])
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"),
        inst(HC, "B/photo.jpg"),
    ])

    // Faces
    try cat.insertFaces([lockedFace(HA, vec: [1, 0]), lockedFace(HC, vec: [0, 1])])

    // OCR text
    try cat.upsertOCR(hash: HA, text: "secret locked text")
    try cat.upsertOCR(hash: HC, text: "visible unlocked text")

    // Lock folder A
    try cat.applyLockedFolders(["A"])
    return (t, cat)
}

// MARK: unassignedAutoFaceIDs

@Test func unassignedAutoFaceIDsExcludesLockedFaceWhenNotRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = false

    let ids = try cat.unassignedAutoFaceIDs()
    // HA is locked — its face must not appear
    // HC is unlocked — its face must appear
    let faceHashes = try cat.dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT id, hash FROM faces ORDER BY id").map {
            (id: $0["id"] as Int64, hash: $0["hash"] as String)
        }
    }
    let lockedFaceID  = faceHashes.first(where: { $0.hash == HA })?.id
    let visibleFaceID = faceHashes.first(where: { $0.hash == HC })?.id

    #expect(lockedFaceID != nil, "sanity: HA must have a face")
    #expect(visibleFaceID != nil, "sanity: HC must have a face")
    #expect(!ids.contains(lockedFaceID!), "locked HA face must be hidden from unassignedAutoFaceIDs")
    #expect(ids.contains(visibleFaceID!),  "unlocked HC face must appear in unassignedAutoFaceIDs")
}

@Test func unassignedAutoFaceIDsShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = true

    let ids = try cat.unassignedAutoFaceIDs()
    let faceCount = try cat.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces") ?? 0
    }
    #expect(ids.count == faceCount, "all faces must appear when revealLocked = true")
}

// MARK: geotaggedAssets (map)

@Test func geotaggedAssetsExcludesLockedWhenNotRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = false

    let assets = try cat.geotaggedAssets()
    let hashes = assets.map(\.hash)
    #expect(!hashes.contains(HA), "locked HA must not appear on the map when not revealed")
    #expect(hashes.contains(HC),  "unlocked HC must appear on the map")
}

@Test func geotaggedAssetsShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = true

    let hashes = Set(try cat.geotaggedAssets().map(\.hash))
    #expect(hashes.contains(HA), "locked HA must appear on the map when revealed")
    #expect(hashes.contains(HC), "unlocked HC must appear on the map when revealed")
}

// MARK: searchOCR

@Test func searchOCRExcludesLockedWhenNotRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = false

    let results = try cat.searchOCR("secret locked")
    #expect(!results.contains(HA), "locked HA OCR text must not appear in search when not revealed")

    let unlocked = try cat.searchOCR("visible unlocked")
    #expect(unlocked.contains(HC), "unlocked HC OCR text must appear in search")
}

@Test func searchOCRShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF2(); defer { t.cleanup() }
    cat.revealLocked = true

    let results = try cat.searchOCR("secret locked")
    #expect(results.contains(HA), "locked HA OCR text must appear when revealLocked = true")
}

// MARK: - LF7: leak-audit fixes

/// Seed for LF7 leak-audit tests:
///  - HA → ONLY in locked /A/photo.jpg (unique camera "LockedCam", tag "secret-tag", GPS London)
///    and ALSO a second copy at /A/copy.jpg (still locked — same folder).
///    visibleInstances tests need a second UNLOCKED copy of HA, seeded separately below.
///  - HC → /B/other.jpg (unlocked, camera "VisibleCam", tag "visible-tag", GPS Paris)
///
/// For distinctCameras/Tags/Places tests: HA has NO unlocked instance, so lockedVisibilityClause
/// must filter it (no non-locked instance EXISTS for HA's hash).
/// For visibleInstances tests: HA has one locked + one unlocked instance (seeded by seededLF7dup).
private func seededLF7() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))

    // HA: locked-only photo (unique camera, tag, place)
    let assetA = AssetRecord(hash: HA, kind: "photo", takenAtMs: 2,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: 51.5074, longitude: -0.1278,
                             cameraModel: "LockedCam", lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil,
                             tagsJSON: "[\"secret-tag\"]")
    // HC: unlocked photo (distinct camera, tag, place)
    let assetC = AssetRecord(hash: HC, kind: "photo", takenAtMs: 1,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: 48.8566, longitude: 2.3522,
                             cameraModel: "VisibleCam", lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil,
                             tagsJSON: "[\"visible-tag\"]")
    try cat.upsert(assets: [assetA, assetC])
    // HA is ONLY in the locked folder /A; HC is in the unlocked /B
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"),   // locked-only copy of HA
        inst(HC, "B/other.jpg"),   // unlocked photo
    ])
    // Geocode
    try cat.upsertGeocode(GeocodeRow(hash: HA, city: "London", region: "England",
                                     country: "United Kingdom", countryCode: "GB"))
    try cat.upsertGeocode(GeocodeRow(hash: HC, city: "Paris", region: "Île-de-France",
                                     country: "France", countryCode: "FR"))
    // Lock folder A
    try cat.applyLockedFolders(["A"])
    return (t, cat)
}

/// Seed variant where HA exists in BOTH /A (locked) AND /B (unlocked) — for visibleInstances tests.
private func seededLF7dup() throws -> (TestDirs, Catalog) {
    let t = try TestDirs()
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let assetA = AssetRecord(hash: HA, kind: "photo", takenAtMs: 2,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: nil, longitude: nil,
                             cameraModel: nil, lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    let assetC = AssetRecord(hash: HC, kind: "photo", takenAtMs: 1,
                             pixelWidth: nil, pixelHeight: nil,
                             latitude: nil, longitude: nil,
                             cameraModel: nil, lensModel: nil, durationSeconds: nil,
                             livePairHash: nil, isLivePairedVideo: false,
                             favorite: false, rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [assetA, assetC])
    // HA has one locked copy (/A) AND one unlocked copy (/B)
    try cat.replaceInstances(inVault: "mac", with: [
        inst(HA, "A/photo.jpg"),   // will be locked
        inst(HA, "B/copy.jpg"),    // will remain unlocked
        inst(HC, "B/other.jpg"),
    ])
    try cat.applyLockedFolders(["A"])
    return (t, cat)
}

// MARK: visibleInstances(forHash:) — Inspector "Also in N other folders" must not reveal locked paths

@Test func visibleInstancesHidesLockedCopyWhenNotRevealed() throws {
    // HA has one locked copy (/A) and one unlocked copy (/B).
    let (t, cat) = try seededLF7dup(); defer { t.cleanup() }
    cat.revealLocked = false

    let visible = try cat.visibleInstances(forHash: HA)
    let dirs = visible.map(\.dirPath)
    #expect(!dirs.contains("A"), "locked /A copy must not appear in visibleInstances when !revealLocked")
    #expect(dirs.contains("B"), "unlocked /B copy must appear in visibleInstances")
}

@Test func visibleInstancesShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF7dup(); defer { t.cleanup() }
    cat.revealLocked = true

    let visible = try cat.visibleInstances(forHash: HA)
    let dirs = visible.map(\.dirPath)
    #expect(dirs.contains("A"), "/A copy must appear when revealLocked = true")
    #expect(dirs.contains("B"), "/B copy must appear when revealLocked = true")
}

@Test func instancesForHashAlwaysUnfilteredForInternalUse() throws {
    // instances(forHash:) must remain unfiltered — used by sidecar writes, deletion, etc.
    let (t, cat) = try seededLF7dup(); defer { t.cleanup() }
    cat.revealLocked = false

    let all = try cat.instances(forHash: HA)
    let dirs = all.map(\.dirPath)
    #expect(dirs.contains("A"), "instances(forHash:) must return locked copies (internal use)")
    #expect(dirs.contains("B"), "instances(forHash:) must return unlocked copies")
}

// MARK: distinctCameras — must not reveal cameras from locked photos

@Test func distinctCamerasHidesLockedCameraWhenNotRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = false

    let cameras = try cat.distinctCameras()
    #expect(!cameras.contains("LockedCam"),  "camera from locked photo must not appear in filter UI")
    #expect(cameras.contains("VisibleCam"), "camera from unlocked photo must appear")
}

@Test func distinctCamerasShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = true

    let cameras = try cat.distinctCameras()
    #expect(cameras.contains("LockedCam"),  "locked camera must appear when revealLocked = true")
    #expect(cameras.contains("VisibleCam"), "unlocked camera must appear when revealLocked = true")
}

// MARK: distinctTags — must not reveal tags from locked photos

@Test func distinctTagsHidesLockedTagWhenNotRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = false

    let tags = try cat.distinctTags()
    #expect(!tags.contains("secret-tag"), "tag from locked photo must not appear in filter UI")
    #expect(tags.contains("visible-tag"), "tag from unlocked photo must appear")
}

@Test func distinctTagsShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = true

    let tags = try cat.distinctTags()
    #expect(tags.contains("secret-tag"), "locked tag must appear when revealLocked = true")
    #expect(tags.contains("visible-tag"), "unlocked tag must appear when revealLocked = true")
}

// MARK: distinctPlaces — must not reveal places from locked photos

@Test func distinctPlacesHidesLockedPlaceWhenNotRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = false

    let places = try cat.distinctPlaces()
    let countryCodes = places.map(\.countryCode)
    let cities = places.map(\.city)
    #expect(!countryCodes.contains("GB"), "locked place (GB) must not appear in filter picker")
    #expect(countryCodes.contains("FR"), "unlocked place (FR) must appear")
    #expect(!cities.contains("London"),  "locked city must not appear in filter picker")
    #expect(cities.contains("Paris"),    "unlocked city must appear")
}

@Test func distinctPlacesShowsAllWhenRevealed() throws {
    let (t, cat) = try seededLF7(); defer { t.cleanup() }
    cat.revealLocked = true

    let places = try cat.distinctPlaces()
    let countryCodes = places.map(\.countryCode)
    #expect(countryCodes.contains("GB"), "locked place must appear when revealLocked = true")
    #expect(countryCodes.contains("FR"), "unlocked place must appear when revealLocked = true")
}
