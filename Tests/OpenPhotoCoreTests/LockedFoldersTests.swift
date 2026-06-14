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
