# Slice 5b — Catalog Snapshot + Confirmed Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A drive carries a disposable copy of the machine-derived catalog + thumbnails so any Mac can browse it instantly (no re-scan/re-hash/re-ML), via a *confirmed* adoption.

**Architecture:** `CatalogSnapshot` (Core) writes `<drive>/.openphoto/catalog-snapshot/` atomically at sync/clone end (a `VACUUM INTO` copy of the catalog + this-drive thumbnails + a `snapshot.json` header), and reads it back to seed the live catalog for instant drive-only browse, then verifies against the authoritative manifest. Drives self-describe their role in `vault.json` so adoption (and the Drives panel) can tell canonical from backup.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT — `swift build`/`swift test`, no Xcode), Swift Testing, GRDB SQLite.

**Spec:** `docs/superpowers/specs/2026-06-10-phase3-slice5b-catalog-snapshot-adoption-design.md`
**Branch:** `phase3-drives`

**Conventions (every task):**
- TDD for Core (T2–T5); App (T6) build-verified + manual. Docs (T1, T7) no code.
- 0 compiler warnings: `swift build 2>&1 | grep -i warning` prints nothing.
- Generated mock files only in temp dirs (`TestDirs`, `makeJPEG`, raw `Data`). **Never** `~/Pictures`/personal folders.
- Do **not** modify `VerifiedCopy`, `Manifest`, the `SyncEngine` copy/verify spine, or the send destinations. **No catalog migration** (no table changes).
- Each task commits with the exact message shown, ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Format discipline:** T1 documents the `catalog-snapshot/` artifact *before* T2 writes it.

**Confirmed reference APIs (already in the codebase — do not redefine):**
- `Catalog` has `public let dbQueue: DatabaseQueue`; `Catalog(at: URL)`; `registerVault(id:role:rootPath:)`, `replaceVaultPresence(vaultID:entries:)`, `vaultPresenceRows(forVault:) -> [VaultPresenceEntry]`, `removeVaultPresence(vaultID:hashes:)`, `timelineItems()`.
- `AssetRecord(hash:kind:takenAtMs:pixelWidth:pixelHeight:latitude:longitude:cameraModel:lensModel:durationSeconds:livePairHash:isLivePairedVideo:favorite:rating:caption:tagsJSON:)`, `FetchableRecord`/`PersistableRecord` (so `AssetRecord.fetchAll(db)` and `record.insert(db, onConflict: .ignore)` work).
- `VaultPresenceEntry(hash:relPath:dirPath:size:driveRelPath:)`.
- `Vault.openOrCreate(at:role:) -> Vault`; `Vault.rootURL`, `.stateDirURL` (=`rootURL/.openphoto`), `.manifestURL`, `.descriptor` (`.vaultID`/`.role`/`.createdAt`/`.formatVersion`/`.app`), `.absoluteURL(forRelativePath:)`.
- `VaultDescriptor(formatVersion:vaultID:role:createdAt:app:)` (all `let`); `VaultRole` (`.local`/`.canonical`/`.backup`).
- `Manifest.read(from:) -> [ManifestEntry]`; `ManifestEntry(hash: ContentHash, path: String, size: Int64, mtime: String)`.
- `ThumbnailStore(cacheDir:)`; `cacheURL(for: ContentHash) -> URL` (`<cacheDir>/<hex[0..2]>/<hex>.jpg`).
- `ContentHash(stringValue:)`, `.stringValue`; `MediaKind.of(filename:) -> MediaKind?` (`.rawValue`).
- `DrivePathMap.driveToMacRelPath(_:sourceBasenames:) -> String`.
- `AtomicFile.write(_ data: Data, to dest: URL)`; `ISO8601Millis.string(from:)`, `.dateLenient(from:) -> Date?`.

---

## Task 1: Document the snapshot format (format-first)

**Files:**
- Modify: `docs/format/vault-format-v1.md` (§7)
- Create: `docs/format/catalog-schema.md`

No code. This lands before the writer so the on-disk format is documented before it's produced.

- [ ] **Step 1: Flesh out §7**

Replace the current §7 stub with a normative spec of the layout:

```
<drive-root>/.openphoto/catalog-snapshot/
  catalog.sqlite          ← clean VACUUM INTO copy of the Mac's catalog (schema: catalog-schema.md)
  thumbs/<hh>/<hash>.jpg   ← content-addressed thumbnails, ONLY this drive's manifest hashes
  snapshot.json           ← {"format_version":1,"catalog_schema_version":4,
                              "source_vault_id":"…","written_at":"ISO-8601","asset_count":N}
```

State: written **atomically** (assembled in `catalog-snapshot.tmp/`, then swapped in) at the **end of each sync and clone**, after verification; **disposable / non-normative / regenerated wholesale**; a reader MUST treat it as an accelerator only and MUST fall back to a re-scan if it's absent, unreadable, or a newer `format_version` than it understands; **`manifest.jsonl` remains authoritative** for what's on the drive.

- [ ] **Step 2: Create `docs/format/catalog-schema.md`**

Document each catalog SQLite table with columns (from `Catalog.swift` migrations v1–v4), then a **Portability key** section. Tables:
- `vaults(id PK, role, rootPath, lastSeenMs)`
- `assets(hash PK, kind, takenAtMs, pixelWidth, pixelHeight, latitude, longitude, cameraModel, lensModel, durationSeconds, livePairHash, isLivePairedVideo, favorite, rating, caption, tagsJSON)`
- `instances(hash, vaultID, relPath, dirPath, size, mtimeMs, PK[vaultID, relPath])`
- `vault_presence(vaultID, hash, relPath, dirPath, size, driveRelPath, PK[vaultID, hash])`
- `pending_deletions(hash PK, relPath, deletedAtMs)`

Portability key (verbatim intent): *A snapshot reader uses ONLY `assets` (hash-keyed machine metadata; the human columns `favorite`/`rating`/`caption`/`tagsJSON` are mirrors of the XMP sidecars, and the sidecars are authoritative — they win on ingest) and this drive's `vault_presence` rows. It MUST ignore `vaults.rootPath`/`lastSeenMs` (the source Mac's local paths), `instances` (the source Mac's local-vault rows), `vault_presence` rows for other `vaultID`s, and `pending_deletions` (the source Mac's delete queue). The drive's `manifest.jsonl` is the authoritative inventory; the snapshot is a disposable accelerator.*

- [ ] **Step 3: Commit**

```bash
git add docs/format/vault-format-v1.md docs/format/catalog-schema.md
git commit -m "docs: Slice 5b — catalog-snapshot format §7 + catalog-schema.md

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `CatalogSnapshot.write`

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift`
- Test: `Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import OpenPhotoCore

/// A drive vault seeded with one manifest entry + a cached thumbnail for that hash, plus a SECOND
/// cached thumbnail for a hash NOT on the drive. Returns (catalog, thumbs, drive, driveHash, otherHash).
private func snapshotFixture(_ t: TestDirs) throws
    -> (Catalog, ThumbnailStore, Vault, String, String) {
    let catalog = try Catalog(at: t.root.appendingPathComponent("cat.sqlite"))
    let thumbs = ThumbnailStore(cacheDir: try t.sub("thumbs"))
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let driveHash = "sha256:" + String(repeating: "a", count: 64)
    let otherHash = "sha256:" + String(repeating: "b", count: 64)
    // An asset row + manifest entry for the drive hash.
    try catalog.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: false, rating: 0, caption: nil, tagsJSON: "[]")])
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: driveHash),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)
    // Two cached thumbs: one for the drive hash, one for an unrelated hash.
    for h in [driveHash, otherHash] {
        let u = thumbs.cacheURL(for: ContentHash(stringValue: h))
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: u)
    }
    return (catalog, thumbs, drive, driveHash, otherHash)
}

@Test func writeProducesSnapshotWithOnlyThisDrivesThumbs() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, otherHash) = try snapshotFixture(t)

    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let snapDir = drive.stateDirURL.appendingPathComponent("catalog-snapshot")
    let fm = FileManager.default
    // catalog.sqlite exists and is a readable SQLite with the asset.
    let dbURL = snapDir.appendingPathComponent("catalog.sqlite")
    #expect(fm.fileExists(atPath: dbURL.path))
    var cfg = Configuration(); cfg.readonly = true
    let q = try DatabaseQueue(path: dbURL.path, configuration: cfg)
    let count = try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") }
    #expect(count == 1)
    // This drive's thumb copied; the unrelated one NOT.
    func thumbRel(_ h: String) -> String {
        let hex = String(h.split(separator: ":").last!)
        return "thumbs/\(hex.prefix(2))/\(hex).jpg"
    }
    #expect(fm.fileExists(atPath: snapDir.appendingPathComponent(thumbRel(driveHash)).path))
    #expect(!fm.fileExists(atPath: snapDir.appendingPathComponent(thumbRel(otherHash)).path))
    // snapshot.json parses with the source vault id.
    let meta = try JSONSerialization.jsonObject(
        with: Data(contentsOf: snapDir.appendingPathComponent("snapshot.json"))) as! [String: Any]
    #expect(meta["source_vault_id"] as? String == drive.descriptor.vaultID)
    #expect(meta["asset_count"] as? Int == 1)
    // Re-running replaces cleanly, no leftover temp dir.
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)
    #expect(!fm.fileExists(atPath: drive.stateDirURL.appendingPathComponent("catalog-snapshot.tmp").path))
    #expect(fm.fileExists(atPath: dbURL.path))
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -20`
Expected: compile failure — `CatalogSnapshot` doesn't exist.

- [ ] **Step 3: Implement `CatalogSnapshot.write`**

Create `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift`:

```swift
import Foundation
import GRDB

/// A drive carries a disposable copy of the Mac's machine-derived catalog + thumbnails under
/// `.openphoto/catalog-snapshot/`, so a fresh Mac can browse instantly. Never a source of truth;
/// regenerated wholesale; the drive's manifest is authoritative. See docs/format §7.
public enum CatalogSnapshot {
    static let dirName = "catalog-snapshot"

    /// Drive-relative path of a hash's thumbnail inside the snapshot (mirrors ThumbnailStore layout).
    static func thumbRelPath(forHash hash: String) -> String {
        let hex = String(hash.split(separator: ":").last ?? "x")
        return "thumbs/\(hex.prefix(2))/\(hex).jpg"
    }

    /// Write the snapshot atomically: VACUUM the live catalog into a clean copy, copy thumbnails for
    /// the drive's manifest hashes, write snapshot.json, then swap the temp dir over the old one.
    public static func write(catalog: Catalog, thumbnails: ThumbnailStore, drive: Vault) throws {
        let fm = FileManager.default
        let hashes = try Manifest.read(from: drive.manifestURL).map { $0.hash.stringValue }

        let tmp = drive.stateDirURL.appendingPathComponent("\(dirName).tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // VACUUM INTO a clean single-file copy (runs OUTSIDE a transaction).
        let dbDest = tmp.appendingPathComponent("catalog.sqlite")
        let escaped = dbDest.path.replacingOccurrences(of: "'", with: "''")
        try catalog.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }

        // Thumbnails — only the drive's hashes.
        for h in hashes {
            let src = thumbnails.cacheURL(for: ContentHash(stringValue: h))
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = tmp.appendingPathComponent(thumbRelPath(forHash: h))
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }

        // Header.
        let meta: [String: Any] = [
            "format_version": 1, "catalog_schema_version": 4,
            "source_vault_id": drive.descriptor.vaultID,
            "written_at": ISO8601Millis.string(from: Date()),
            "asset_count": hashes.count]
        try AtomicFile.write(try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .prettyPrinted]),
                             to: tmp.appendingPathComponent("snapshot.json"))

        // Atomic swap.
        let final = drive.stateDirURL.appendingPathComponent(dirName)
        if fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: final)
        }
    }
}
```

- [ ] **Step 4: Run — verify pass + no warnings**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -10` → pass.
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift
git commit -m "feat(core): CatalogSnapshot.write — atomic VACUUM-INTO copy + this-drive thumbnails + snapshot.json

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `CatalogSnapshot.import` (+ `Catalog.insertAssetsIfAbsent`)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift`
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Test: `Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CatalogSnapshotTests.swift`:

```swift
@Test func importSeedsAFreshCatalogForDriveOnlyBrowse() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    // Presence on the SOURCE so the snapshot's vault_presence has this drive's row.
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    // Adopt into a FRESH empty catalog + fresh thumb cache.
    let fresh = try Catalog(at: t.root.appendingPathComponent("fresh.sqlite"))
    let freshThumbs = ThumbnailStore(cacheDir: try t.sub("fresh-thumbs"))
    let result = try CatalogSnapshot.import(from: drive, into: fresh, thumbnails: freshThumbs)

    #expect(result.assets >= 1)
    let items = try fresh.timelineItems()
    #expect(items.contains { $0.hash == driveHash && $0.driveRelPath != nil })   // browses drive-only
    #expect(FileManager.default.fileExists(
        atPath: freshThumbs.cacheURL(for: ContentHash(stringValue: driveHash)).path))   // thumb copied
}

@Test func importNeverClobbersLocalHumanMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    // A presence row for a DIFFERENT vault in the snapshot DB must be ignored by import.
    try catalog.replaceVaultPresence(vaultID: "other-vault", entries: [
        VaultPresenceEntry(hash: "sha256:" + String(repeating: "c", count: 64), relPath: "x", dirPath: "x",
                           size: 1, driveRelPath: "x")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    // Live catalog already knows this asset as a FAVORITE.
    let live = try Catalog(at: t.root.appendingPathComponent("live.sqlite"))
    try live.upsert(assets: [AssetRecord(hash: driveHash, kind: "photo", takenAtMs: 1,
        pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
        lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
        favorite: true, rating: 5, caption: "mine", tagsJSON: "[]")])

    _ = try CatalogSnapshot.import(from: drive, into: live, thumbnails: ThumbnailStore(cacheDir: try t.sub("lt")))

    let fav = try live.dbQueue.read { db in
        try Bool.fetchOne(db, sql: "SELECT favorite FROM assets WHERE hash = ?", arguments: [driveHash]) }
    #expect(fav == true)   // insert-if-absent kept the local human metadata
    #expect(try live.vaultPresenceRows(forVault: "other-vault").isEmpty)   // other vault ignored
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -15`
Expected: compile failure — `CatalogSnapshot.import` / `insertAssetsIfAbsent` don't exist.

- [ ] **Step 3: Add `Catalog.insertAssetsIfAbsent`**

In `Catalog.swift`, after `upsert(assets:)`:

```swift
    /// Insert assets that don't already exist; never overwrite an existing row (so a snapshot
    /// import can't clobber the Mac's authoritative human metadata).
    public func insertAssetsIfAbsent(_ assets: [AssetRecord]) throws {
        try dbQueue.write { db in
            for a in assets { try a.insert(db, onConflict: .ignore) }
        }
    }
```

- [ ] **Step 4: Add `AdoptionImport` + `import` to `CatalogSnapshot.swift`**

```swift
public struct AdoptionImport: Sendable, Equatable {
    public var assets: Int      // assets read from the snapshot
    public var present: Int     // this-drive presence rows seeded
    public init(assets: Int, present: Int) { self.assets = assets; self.present = present }
}

extension CatalogSnapshot {
    /// Seed the live catalog from a drive's snapshot for instant drive-only browse. Reads ONLY the
    /// portable parts (assets + this drive's vault_presence) from a READ-ONLY open of the snapshot DB
    /// (never writes to the drive). Assets are inserted-if-absent (never clobber local metadata).
    public static func `import`(from drive: Vault, into catalog: Catalog,
                                thumbnails: ThumbnailStore) throws -> AdoptionImport {
        let snapDir = drive.stateDirURL.appendingPathComponent(dirName)
        let dbURL = snapDir.appendingPathComponent("catalog.sqlite")
        var cfg = Configuration(); cfg.readonly = true
        let snap = try DatabaseQueue(path: dbURL.path, configuration: cfg)

        let assets = try snap.read { db in try AssetRecord.fetchAll(db) }
        let presence: [VaultPresenceEntry] = try snap.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hash, relPath, dirPath, size, driveRelPath FROM vault_presence WHERE vaultID = ?
                """, arguments: [drive.descriptor.vaultID]).map {
                VaultPresenceEntry(hash: $0["hash"], relPath: $0["relPath"], dirPath: $0["dirPath"],
                                   size: $0["size"], driveRelPath: $0["driveRelPath"])
            }
        }

        try catalog.insertAssetsIfAbsent(assets)
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: presence)

        // Copy thumbnails into the live cache (skip ones already there).
        let fm = FileManager.default
        let thumbsDir = snapDir.appendingPathComponent("thumbs")
        if let en = fm.enumerator(at: thumbsDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "jpg" {
                let stem = u.deletingPathExtension().lastPathComponent
                let dst = thumbnails.cacheURL(for: ContentHash(stringValue: "sha256:" + stem))
                guard !fm.fileExists(atPath: dst.path) else { continue }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: u, to: dst)
            }
        }
        return AdoptionImport(assets: assets.count, present: presence.count)
    }
}
```

- [ ] **Step 5: Run — verify pass + no warnings + full suite**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -10` → pass.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift Sources/OpenPhotoCore/Catalog/Catalog.swift Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift
git commit -m "feat(core): CatalogSnapshot.import seeds assets+presence+thumbs (insert-if-absent) for drive-only browse

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `CatalogSnapshot.verifyAdoption` (manifest wins)

**Files:**
- Modify: `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift`
- Test: `Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CatalogSnapshotTests.swift`:

```swift
@Test func verifyAdoptionMakesManifestWin() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let inManifest = "sha256:" + String(repeating: "a", count: 64)
    let staleInPresence = "sha256:" + String(repeating: "b", count: 64)   // not in the manifest
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: inManifest),
        path: "Pictures/rome/IMG_1.jpg", size: 3, mtime: "2022-10-07T14:23:01.000Z")],
        to: drive.manifestURL)

    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    // Presence currently has ONLY the stale hash (snapshot was out of date); the manifest hash is missing.
    try cat.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: staleInPresence, relPath: "old.jpg", dirPath: "", size: 1, driveRelPath: "Pictures/old.jpg")])

    try CatalogSnapshot.verifyAdoption(drive: drive, into: cat, sourceBasenames: ["Pictures"])

    let rows = try cat.vaultPresenceRows(forVault: drive.descriptor.vaultID)
    #expect(rows.map(\.hash) == [inManifest])           // stale dropped, manifest entry added
    #expect(rows.first?.relPath == "rome/IMG_1.jpg")    // mac-relative via DrivePathMap (Pictures stripped)
    // A minimal asset was inserted for the manifest hash.
    let kind = try cat.dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT kind FROM assets WHERE hash = ?", arguments: [inManifest]) }
    #expect(kind == "photo")
}

@Test func adoptionRoundTripMatchesManifest() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (catalog, thumbs, drive, driveHash, _) = try snapshotFixture(t)
    try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: [
        VaultPresenceEntry(hash: driveHash, relPath: "rome/IMG_1.jpg", dirPath: "rome",
                           size: 3, driveRelPath: "Pictures/rome/IMG_1.jpg")])
    try CatalogSnapshot.write(catalog: catalog, thumbnails: thumbs, drive: drive)

    let fresh = try Catalog(at: t.root.appendingPathComponent("fresh.sqlite"))
    _ = try CatalogSnapshot.import(from: drive, into: fresh, thumbnails: ThumbnailStore(cacheDir: try t.sub("ft")))
    try CatalogSnapshot.verifyAdoption(drive: drive, into: fresh, sourceBasenames: ["Pictures"])

    let manifestHashes = Set(try Manifest.read(from: drive.manifestURL).map { $0.hash.stringValue })
    let browseHashes = Set(try fresh.timelineItems().filter { $0.driveRelPath != nil }.map(\.hash))
    #expect(browseHashes == manifestHashes)
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -15`
Expected: compile failure — `verifyAdoption` doesn't exist.

- [ ] **Step 3: Implement `verifyAdoption`**

Append to the `extension CatalogSnapshot` (or add a new extension) in `CatalogSnapshot.swift`:

```swift
extension CatalogSnapshot {
    /// Reconcile an adopted drive's presence against its authoritative manifest (the snapshot may be
    /// stale). No re-hash, no file reads beyond the manifest: drop presence whose hash isn't in the
    /// manifest; add presence (and a minimal asset) for every manifest hash that's missing.
    public static func verifyAdoption(drive: Vault, into catalog: Catalog,
                                      sourceBasenames: [String]) throws {
        let manifest = try Manifest.read(from: drive.manifestURL)
        let manifestHashes = Set(manifest.map { $0.hash.stringValue })
        let current = try catalog.vaultPresenceRows(forVault: drive.descriptor.vaultID)
        let currentByHash = Dictionary(current.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })

        var merged: [VaultPresenceEntry] = current.filter { manifestHashes.contains($0.hash) }
        var minimalAssets: [AssetRecord] = []
        for e in manifest where currentByHash[e.hash.stringValue] == nil {
            let hash = e.hash.stringValue
            let mac = DrivePathMap.driveToMacRelPath(e.path, sourceBasenames: sourceBasenames)
            merged.append(VaultPresenceEntry(hash: hash, relPath: mac,
                dirPath: (mac as NSString).deletingLastPathComponent, size: e.size, driveRelPath: e.path))
            let kind = MediaKind.of(filename: e.path)?.rawValue ?? MediaKind.photo.rawValue
            let takenMs = ISO8601Millis.dateLenient(from: e.mtime).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            minimalAssets.append(AssetRecord(hash: hash, kind: kind, takenAtMs: takenMs,
                pixelWidth: nil, pixelHeight: nil, latitude: nil, longitude: nil, cameraModel: nil,
                lensModel: nil, durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false,
                favorite: false, rating: 0, caption: nil, tagsJSON: "[]"))
        }
        try catalog.insertAssetsIfAbsent(minimalAssets)
        try catalog.replaceVaultPresence(vaultID: drive.descriptor.vaultID, entries: merged)
    }
}
```

- [ ] **Step 4: Run — verify pass + no warnings**

Run: `swift test --filter CatalogSnapshotTests 2>&1 | tail -10` → all pass.
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift Tests/OpenPhotoCoreTests/CatalogSnapshotTests.swift
git commit -m "feat(core): CatalogSnapshot.verifyAdoption reconciles adopted presence to the authoritative manifest

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `Vault.writingRole` + wire into clone

**Files:**
- Modify: `Sources/OpenPhotoCore/Vault/Vault.swift`
- Modify: `Sources/OpenPhotoApp/AppState.swift` (`cloneToBackup`)
- Test: `Tests/OpenPhotoCoreTests/VaultRoleTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/VaultRoleTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func writingRoleRewritesVaultJsonPreservingID() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let root = try t.sub("drive")
    let v = try Vault.openOrCreate(at: root, role: .canonical)
    let id = v.descriptor.vaultID

    let updated = try v.writingRole(.backup)
    #expect(updated.descriptor.role == .backup)
    #expect(updated.descriptor.vaultID == id)

    // Re-opening reads the on-disk role (openOrCreate ignores the passed role for an existing vault).
    let reopened = try Vault.openOrCreate(at: root, role: .canonical)
    #expect(reopened.descriptor.role == .backup)
    #expect(reopened.descriptor.vaultID == id)
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter VaultRoleTests 2>&1 | tail -15`
Expected: compile failure — `writingRole` doesn't exist.

- [ ] **Step 3: Add `writingRole` to `Vault.swift`**

Add to `Vault` (after `openOrCreate`):

```swift
    /// Rewrite this vault's vault.json with a new role, preserving vault_id/created_at/format_version.
    /// Atomic. Returns the updated Vault. Used when a drive becomes a backup (clone) or canonical.
    public func writingRole(_ role: VaultRole) throws -> Vault {
        let desc = VaultDescriptor(formatVersion: descriptor.formatVersion, vaultID: descriptor.vaultID,
                                   role: role, createdAt: descriptor.createdAt, app: descriptor.app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(desc),
                             to: stateDirURL.appendingPathComponent("vault.json"))
        return Vault(rootURL: rootURL, descriptor: desc)
    }
```

- [ ] **Step 4: Run — verify pass**

Run: `swift test --filter VaultRoleTests 2>&1 | tail -8` → pass.

- [ ] **Step 5: Wire into `cloneToBackup`**

In `Sources/OpenPhotoApp/AppState.swift`, in `cloneToBackup`, immediately after the existing `try? lib.catalog.registerVault(id: target.descriptor.vaultID, role: "backup", rootPath: target.rootURL.path)` line, add:

```swift
        _ = try? target.writingRole(.backup)   // self-describe on disk so any Mac identifies it correctly
```

- [ ] **Step 6: Build clean + commit**

Run: `swift build 2>&1 | tail -3` → clean.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green.

```bash
git add Sources/OpenPhotoCore/Vault/Vault.swift Sources/OpenPhotoApp/AppState.swift Tests/OpenPhotoCoreTests/VaultRoleTests.swift
git commit -m "feat(core): Vault.writingRole rewrites vault.json role; clone self-describes a backup on disk

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: App — write hook + confirmed adoption + role labels

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`
- Modify: `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift` (write hook after sync)

App integration → build-verified + manual. Off-main for all I/O (mirror the existing sync/clone pattern).

- [ ] **Step 1: Snapshot write hook (after sync + clone)**

- In `cloneToBackup` (AppState), after the role flip + `refreshCanonicalPresence`, add (off-main):
```swift
        let cat = lib.catalog, thumbs = lib.thumbnails
        await Task.detached(priority: .utility) { try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: target) }.value
```
- After a successful sync apply: in `SyncPlanSheet.swift`, where `engine.apply(...)` completes successfully (the result handler), call the same `CatalogSnapshot.write(catalog: lib.catalog, thumbnails: lib.thumbnails, drive: drive)` off-main as the LAST step. (`lib`/`drive` are already in scope there; if not, thread them through.) Non-fatal on failure (`try?`).

- [ ] **Step 2: Confirmed-adoption detection + orchestration (AppState)**

Add:
```swift
    /// A connected drive that carries a catalog-snapshot whose contents this Mac doesn't yet know
    /// (no vault_presence) — a candidate to adopt. nil if none.
    var adoptableDrive: VaultRecord? {
        guard let lib = library else { return nil }
        return durableVaults.first { vr in
            driveIsPresent(vr)
            && FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: vr.rootPath).appendingPathComponent(".openphoto/catalog-snapshot/catalog.sqlite").path)
            && ((try? lib.catalog.vaultPresenceRows(forVault: vr.id))?.isEmpty ?? true)
        }
    }

    /// Photos a candidate drive's snapshot says it holds (from snapshot.json asset_count) — for the prompt.
    func adoptablePhotoCount(_ vr: VaultRecord) -> Int {
        let url = URL(fileURLWithPath: vr.rootPath).appendingPathComponent(".openphoto/catalog-snapshot/snapshot.json")
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return meta["asset_count"] as? Int ?? 0
    }

    /// Adopt a drive: import its snapshot for instant browse, then verify against the manifest.
    func adoptDrive(_ vr: VaultRecord) async {
        guard let lib = library, let drive = openVault(for: vr) else { return }
        let cat = lib.catalog, thumbs = lib.thumbnails
        let bases = lib.vaults.map { $0.rootURL.lastPathComponent }
        await Task.detached(priority: .userInitiated) {
            _ = try? CatalogSnapshot.import(from: drive, into: cat, thumbnails: thumbs)
            try? CatalogSnapshot.verifyAdoption(drive: drive, into: cat, sourceBasenames: bases)
        }.value
        reloadCanonicalPresence()
        try? refreshQueries()
    }
```
(The drive is registered with its real on-disk role at add time — `addDriveViaPanel` already registers `vault.descriptor.role.rawValue` from `openOrCreate`, so a canonical-role drive becomes the canonical when the Mac has none; no extra "set canonical" code is needed for the no-canonical case.)

- [ ] **Step 3: Adoption prompt (DrivesView)**

In `DrivesView`, add an `.alert`/banner driven by `state.adoptableDrive`: when non-nil, prompt *"'<basename>' carries a photo library (\(state.adoptablePhotoCount(vr)) photos). Adopt it so you can browse it here?"* with **Adopt** (`Task { await state.adoptDrive(vr) }`) and **Not now** (dismiss). Use a local `@State var adoptTarget: VaultRecord?` set from `state.adoptableDrive` on appear / on drives change, so "Not now" can suppress it for the session.

- [ ] **Step 4: Role labels (verify)**

Confirm the Drives row status (the 5a `statusText` role label) now reads "Backup" for a cloned drive (its `vault.json` role is written in Task 5) and exactly one drive reads "Canonical". No new code expected — just verify in the manual pass; if a non-canonical drive still mislabels, ensure the label reads `vr.role` (the catalog role, which `registerVault` set) — already the case from 5a.

- [ ] **Step 5: Build clean + rebuild bundle + commit**

Run: `swift build 2>&1 | tail -3` and `swift build 2>&1 | grep -i warning` → clean, no warnings.
Run: `swift test 2>&1 | tail -5` → green.
Run: `./scripts/make-app.sh 2>&1 | tail -2` → rebuild the bundle.

Manual (user): sync/clone leaves `.openphoto/catalog-snapshot/` on the drive; *forget* a drive then *re-add* it → the **Adopt** prompt appears → Adopt → photos browse instantly; a cloned backup reads "Backup".

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Drives/DrivesView.swift Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift
git commit -m "feat(app): write catalog snapshot at sync/clone end; confirmed adoption imports + verifies; role labels

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Add the changelog entry** (after the most recent 2026-06-10 bullet):

```markdown
- **2026-06-10** — Phase 3 **Slice 5b (Catalog snapshot + confirmed adoption)** implemented on `phase3-drives` (second Slice-5 sub-slice). A drive now carries a **disposable copy of the machine-derived index** at `<drive>/.openphoto/catalog-snapshot/` (`catalog.sqlite` via `VACUUM INTO`, `thumbs/` for only this drive's manifest hashes, `snapshot.json`), written **atomically** (`temp dir → replaceItemAt`) at the end of each sync and clone — documented in format §7 + the new `docs/format/catalog-schema.md` (with a portability key: a reader uses only `assets` + this drive's `vault_presence`; the manifest is authoritative). **Confirmed adoption** (a prompt, never silent): plugging a snapshot-carrying drive into a Mac that doesn't know it offers "Adopt", which **imports** the snapshot (assets insert-if-absent so local human metadata is never clobbered + this-drive presence + thumbnails) for **instant drive-only browse**, then **verifies against the manifest in the background** (manifest wins — stale snapshot rows dropped, manifest-only entries added with minimal assets). Drives now **self-describe their role in `vault.json`** (`Vault.writingRole`; a clone writes `backup`), closing the 5a deferral so canonical-vs-backup is unambiguous and exactly one drive reads "Canonical". The snapshot is rebuildable, never a source of truth, never merged. **No catalog migration.** Spec: `docs/superpowers/specs/2026-06-10-phase3-slice5b-catalog-snapshot-adoption-design.md`. Remaining: **5c** (canonical management & migration — designate/change the canonical, agreement-gated promotion, demote the old), then merge `phase3-drives` → `main`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: record Slice 5b (catalog snapshot + adoption) in master changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** §3.1/§3.2 snapshot layout+write → T1+T2; §3.3 schema doc → T1; §3.4 import → T3; §3.5 verify → T4; §3.6 app hooks+confirmed adoption → T6; §3.7 role-write → T5; §6 tests → T2–T5. No gaps.
- **Type consistency:** `CatalogSnapshot.write(catalog:thumbnails:drive:)`, `import(from:into:thumbnails:) -> AdoptionImport`, `verifyAdoption(drive:into:sourceBasenames:)`, `Catalog.insertAssetsIfAbsent(_:)`, `Vault.writingRole(_:)`, `AppState.adoptDrive(_:)`/`adoptableDrive`/`adoptablePhotoCount(_:)` are used identically across tasks.
- **Format discipline:** T1 (docs) precedes T2 (writer). **No catalog migration** (no table changes; `catalog_schema_version: 4` matches the existing v4).
- **Invariants:** import opens the snapshot DB **read-only** (never writes the drive); assets insert-if-absent (no clobber); manifest authoritative in verify; atomic snapshot swap.
