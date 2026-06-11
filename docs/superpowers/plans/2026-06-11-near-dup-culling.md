# Near-duplicate / burst culling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Tidy Up" surface that groups redundant photos in two modes — **Bursts** (CLIP cosine + time window) and **Duplicates** (perceptual dHash within the same folder) — and lets the user keep the best and bin the rest.

**Architecture:** One small new derivation (`PHashStage` → `phash` table, catalog migration v10) plus pure, unit-tested grouper/keeper functions (the `FaceClusterer` pattern). Bursts reuse the existing `embeddings`; grouping is on-demand off-main (the `loadPeople` pattern); deletion reuses the existing recoverable `delete`→bin path. Catalog-only, no vault-format change.

**Tech Stack:** Swift 6 · SwiftUI · SwiftPM **Command Line Tools only** (`swift build` / `swift test`, **NO Xcode**) · GRDB · CoreGraphics/ImageIO · macOS 15.

---

## Hard rules (every task)

- **Toolchain:** `swift build` / `swift test` only. Never Xcode.
- **Zero warnings:** after each task, `swift build 2>&1 | grep -i warning` **and** `swift build --build-tests 2>&1 | grep -i warning` must both be empty.
- **TDD for Core** (Tasks 1–3: failing test first). **Build-verified for App** (Tasks 4–5).
- **No real user data.** All test images are generated via CoreGraphics into `TestDirs` temp dirs. Never read `~/Pictures`/`~/Movies` or any personal folder.
- **Machine-derived → catalog only.** The `phash` table is a rebuildable cache (migration v10). **No sidecar writes, no `vault-format-v1.md` change.**
- **Commit** each task with the EXACT message in the task, ending with:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Do NOT modify** `Scanner`, `MetadataExtractor`, `ThumbnailStore`, `SyncEngine`, `SemanticIndex`, `FaceClusterer`, or the existing `delete` path — they are **used, not changed**.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OpenPhotoCore/Cull/PerceptualHash.swift` (create) | dHash + Hamming. | 1 |
| `Sources/OpenPhotoCore/Cull/FocusMeasure.swift` (create) | Variance-of-Laplacian sharpness. | 1 |
| `Tests/OpenPhotoCoreTests/PerceptualHashTests.swift` (create) | dHash/Focus tests + shared `writeCheckerJPEG`. | 1 |
| `Sources/OpenPhotoCore/Catalog/Catalog.swift` (modify) | Migration v10 (`phash`) + `schemaVersion` 9→10. | 2 |
| `Sources/OpenPhotoCore/Catalog/Catalog+PHash.swift` (create) | `upsertPHash`, `phashRowsWithDirPath`. | 2 |
| `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift` (modify) | `embeddingsWithTakenAt`. | 2 |
| `Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift` (modify) | `eligibleKind` `"phash"` case. | 2 |
| `Sources/OpenPhotoCore/Derivation/PHashStage.swift` (create) | The derivation stage. | 2 |
| `Tests/OpenPhotoCoreTests/PHashStageTests.swift` (create) | Stage + table + pending + migration. | 2 |
| `Sources/OpenPhotoCore/Cull/BurstGrouper.swift` (create) | Time+cosine grouping. | 3 |
| `Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift` (create) | Same-folder pHash grouping. | 3 |
| `Sources/OpenPhotoCore/Cull/KeeperSelector.swift` (create) | `CullMode`, `Candidate`, keeper/evict. | 3 |
| `Tests/OpenPhotoCoreTests/CullGrouperTests.swift` (create) | Grouper + keeper tests. | 3 |
| `Sources/OpenPhotoApp/AppState.swift` (modify) | `SidebarItem.tidyUp`, cull state, `loadCullGroups`, `PHashStage` in registry. | 4 |
| `Sources/OpenPhotoApp/OpenPhotoApp.swift` (modify) | `case .tidyUp` detail arm. | 4 |
| `Sources/OpenPhotoApp/Cleanup/CleanupView.swift` (create) | The Tidy Up surface. | 5 |
| `docs/format/catalog-schema.md` (modify) | `phash` table (v10). | 6 |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` (modify) | §10.5 DONE + changelog. | 6 |

---

### Task 1: `PerceptualHash` + `FocusMeasure`

**Files:** Create `Sources/OpenPhotoCore/Cull/PerceptualHash.swift`, `Sources/OpenPhotoCore/Cull/FocusMeasure.swift`, `Tests/OpenPhotoCoreTests/PerceptualHashTests.swift`.

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/PerceptualHashTests.swift`:

```swift
import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Render a `size`×`size` checkerboard JPEG (rich horizontal+vertical structure → a non-degenerate
/// dHash). `invert` swaps the squares; `quality` controls JPEG compression. Shared with PHashStageTests.
func writeCheckerJPEG(at url: URL, cell: Int = 8, invert: Bool = false,
                      quality: Double = 0.9, size: Int = 64) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cells = size / cell
    for cy in 0..<cells {
        for cx in 0..<cells {
            var on = (cx + cy) % 2 == 0
            if invert { on.toggle() }
            ctx.setFillColor(CGColor(gray: on ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: cx * cell, y: cy * cell, width: cell, height: cell))
        }
    }
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func dHashNearForReencodeFarForDifferent() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let a = t.root.appendingPathComponent("a.jpg")
    let a2 = t.root.appendingPathComponent("a2.jpg")   // same image, heavier compression
    let b = t.root.appendingPathComponent("b.jpg")     // inverted checkerboard (different image)
    try writeCheckerJPEG(at: a, quality: 0.95)
    try writeCheckerJPEG(at: a2, quality: 0.6)
    try writeCheckerJPEG(at: b, invert: true, quality: 0.95)
    let ha = PerceptualHash.compute(imageAt: a)!
    let ha2 = PerceptualHash.compute(imageAt: a2)!
    let hb = PerceptualHash.compute(imageAt: b)!
    let near = PerceptualHash.hamming(ha, ha2)
    let far = PerceptualHash.hamming(ha, hb)
    #expect(near <= 8)        // a re-encode of the same image stays close
    #expect(near < far)       // a different image is reliably farther
}

@Test func hammingCountsDifferingBits() {
    #expect(PerceptualHash.hamming(0, 0) == 0)
    #expect(PerceptualHash.hamming(0, 0b1011) == 3)
    #expect(PerceptualHash.hamming(Int64(bitPattern: ~0), 0) == 64)
}

@Test func computeReturnsNilForNonImage() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let bad = t.root.appendingPathComponent("bad.jpg")
    try Data("not an image".utf8).write(to: bad)
    #expect(PerceptualHash.compute(imageAt: bad) == nil)
}

@Test func sharpImageScoresHigherThanFlat() {
    // A high-contrast checkerboard CGImage vs a flat gray one.
    func checker(_ flat: Bool) -> CGImage {
        let s = 64
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if flat {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        } else {
            for cy in 0..<8 { for cx in 0..<8 {
                ctx.setFillColor(CGColor(gray: (cx + cy) % 2 == 0 ? 1 : 0, alpha: 1))
                ctx.fill(CGRect(x: cx * 8, y: cy * 8, width: 8, height: 8))
            } }
        }
        return ctx.makeImage()!
    }
    #expect(FocusMeasure.varianceOfLaplacian(checker(false)) > FocusMeasure.varianceOfLaplacian(checker(true)))
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter dHash 2>&1 | tail -5` → "cannot find 'PerceptualHash'".

- [ ] **Step 3: Create `Sources/OpenPhotoCore/Cull/PerceptualHash.swift`:**

```swift
import Foundation
import CoreGraphics
import ImageIO

/// A 64-bit perceptual image fingerprint (difference-hash / dHash) for near-duplicate detection.
/// Deterministic, no ML model: downsample to 9×8 grayscale, emit one bit per adjacent-pixel
/// comparison. Near-identical images (re-encode / resize / recompress) land within a small Hamming
/// distance; visually different images are far apart.
public enum PerceptualHash {
    /// dHash of the image at `url`, or nil if it can't be decoded.
    public static func compute(imageAt url: URL) -> Int64? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) else { return nil }
        return dHash(cg)
    }

    /// dHash of a CGImage: 9×8 grayscale → 64 row-wise adjacent-pixel comparisons.
    public static func dHash(_ image: CGImage) -> Int64? {
        let w = 9, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        var i = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if buf[row * w + col] > buf[row * w + col + 1] { bits |= (UInt64(1) << UInt64(i)) }
                i += 1
            }
        }
        return Int64(bitPattern: bits)
    }

    /// Number of differing bits between two dHashes.
    public static func hamming(_ a: Int64, _ b: Int64) -> Int {
        (UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount
    }
}
```

- [ ] **Step 4: Create `Sources/OpenPhotoCore/Cull/FocusMeasure.swift`:**

```swift
import Foundation
import CoreGraphics

/// Sharpness estimate via the variance of the Laplacian (a focus measure). Higher = sharper.
/// Used to pick the in-focus frame of a burst. Pure; operates on a (cached) CGImage.
public enum FocusMeasure {
    public static func varianceOfLaplacian(_ image: CGImage) -> Double {
        let w = min(image.width, 256), h = min(image.height, 256)
        guard w > 2, h > 2 else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(buf[y * w + x])
                let lap = 4 * c - Double(buf[(y - 1) * w + x]) - Double(buf[(y + 1) * w + x])
                              - Double(buf[y * w + x - 1]) - Double(buf[y * w + x + 1])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
```

- [ ] **Step 5: Run + clean build** — `swift test --filter "dHash|hamming|Sharp|NonImage" 2>&1 | tail -8` → all pass. `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → empty. (If `dHashNearForReencode…` is ever flaky on the `near <= 8` bound, the `near < far` assertion is the real invariant — but do not loosen without re-running a few times first.)

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Cull/PerceptualHash.swift Sources/OpenPhotoCore/Cull/FocusMeasure.swift Tests/OpenPhotoCoreTests/PerceptualHashTests.swift
git commit -m "$(cat <<'EOF'
feat(cull): perceptual dHash + variance-of-Laplacian sharpness

PerceptualHash.compute/dHash/hamming — a 64-bit difference-hash for near-duplicate detection
(deterministic, no model). FocusMeasure.varianceOfLaplacian — a focus measure for picking the
sharp frame of a burst. TDD with generated checkerboard images.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `phash` table (migration v10) + `PHashStage`

**Files:** Modify `Catalog.swift`, `Catalog+Embeddings.swift`, `Catalog+Derivation.swift`; create `Catalog+PHash.swift`, `Derivation/PHashStage.swift`, `Tests/OpenPhotoCoreTests/PHashStageTests.swift`.

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/PHashStageTests.swift` (reuses `writeCheckerJPEG` from Task 1, same test target):

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func photoAsset(_ hash: String) -> AssetRecord {
    AssetRecord(hash: hash, kind: "photo", takenAtMs: 1, pixelWidth: 64, pixelHeight: 64,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

@Test func schemaIsV10() { #expect(Catalog.schemaVersion == 10) }

@Test func phashStageWritesRowSurfacedWithDirPath() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let img = t.root.appendingPathComponent("p.jpg"); try writeCheckerJPEG(at: img)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    try cat.replaceInstances(inVault: "v", with: [InstanceRecord(hash: h, vaultID: "v",
        relPath: "trip/p.jpg", dirPath: "trip", size: 1, mtimeMs: 1)])
    let ok = await PHashStage().run(hash: h, url: img, catalog: cat)
    #expect(ok)
    let rows = try cat.phashRowsWithDirPath()
    #expect(rows.contains { $0.hash == h && $0.dirPath == "trip" })
}

@Test func phashSurfacesDriveOnlyAsset() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "b", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    try cat.upsertPHash(hash: h, value: 12345)
    // No local instance — only drive presence:
    try cat.replaceVaultPresence(vaultID: "drive", entries: [
        VaultPresenceEntry(hash: h, relPath: "trip/x.jpg", dirPath: "trip", size: 1,
                           driveRelPath: "Drive/trip/x.jpg")])
    #expect(try cat.phashRowsWithDirPath().contains { $0.hash == h && $0.dirPath == "trip" && $0.value == 12345 })
}

@Test func pendingDerivationIncludesPhotosForPhash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "c", count: 64)
    try cat.upsert(assets: [photoAsset(h)])
    #expect(try cat.pendingDerivation(stage: "phash").contains(h))
}

@Test func embeddingsWithTakenAtJoinsAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    let h = "sha256:" + String(repeating: "d", count: 64)
    var a = photoAsset(h); a = AssetRecord(hash: h, kind: "photo", takenAtMs: 999, pixelWidth: 64,
        pixelHeight: 64, latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil,
        durationSeconds: nil, livePairHash: nil, isLivePairedVideo: false, favorite: false,
        rating: 0, caption: nil, tagsJSON: "[]")
    try cat.upsert(assets: [a])
    try cat.upsertEmbedding(hash: h, model: "m", dim: 3, vector: [1, 0, 0])
    let rows = try cat.embeddingsWithTakenAt(model: "m")
    #expect(rows.count == 1)
    #expect(rows[0].hash == h && rows[0].takenAtMs == 999 && rows[0].vector.count == 3)
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter "schemaIsV10|phash|embeddingsWithTakenAt" 2>&1 | tail -6` → fails (schemaVersion 9; no `phash`/`PHashStage`).

- [ ] **Step 3: Add migration v10 + bump `schemaVersion`** in `Sources/OpenPhotoCore/Catalog/Catalog.swift`. Change `public static let schemaVersion = 9` → `= 10`. Insert this block immediately **after** the `registerMigration("v9")` block and **before** `try migrator.migrate(dbQueue)`:

```swift
        migrator.registerMigration("v10") { db in
            // Perceptual image hash (dHash) per photo — rebuildable cache, 100% machine-derived
            // (a deterministic function of the image bytes). Catalog-only: NO sidecar, NO format
            // change. Dropping it re-derives by re-running PHashStage.
            try db.create(table: "phash") { t in
                t.primaryKey("hash", .text)            // → assets.hash
                t.column("value", .integer).notNull()  // 64-bit dHash, stored as signed Int64
            }
        }
```

- [ ] **Step 4: Create `Sources/OpenPhotoCore/Catalog/Catalog+PHash.swift`:**

```swift
import Foundation
import GRDB

extension Catalog {
    /// Store (replace) the perceptual hash for an asset.
    public func upsertPHash(hash: String, value: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO phash (hash, value) VALUES (?, ?)",
                           arguments: [hash, value])
        }
    }

    /// (hash, dirPath, dHash) for every photo with a phash, over the timeline union — so `dirPath`
    /// is per-instance and covers local ∪ drive-only. Feeds DuplicateGrouper's same-folder bucketing.
    public func phashRowsWithDirPath() throws -> [(hash: String, dirPath: String, value: Int64)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.hash AS hash, u.dirPath AS dirPath, p.value AS value
                FROM (\(Self.timelineSQL)) u JOIN phash p ON p.hash = u.hash
                """).map { ($0["hash"], $0["dirPath"], $0["value"]) }
        }
    }
}
```

- [ ] **Step 5: Add `embeddingsWithTakenAt`** to `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift` (after `allEmbeddings`; reuses the file-private `Self.unpackFloat16`):

```swift
    /// (hash, takenAtMs, vector) for `model` — embeddings joined to assets. Feeds BurstGrouper.
    public func embeddingsWithTakenAt(model: String) throws -> [(hash: String, takenAtMs: Int64, vector: [Float])] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.hash AS hash, a.takenAtMs AS takenAtMs, e.dim AS dim, e.vector AS vector
                FROM embeddings e JOIN assets a ON a.hash = e.hash
                WHERE e.model = ?
                """, arguments: [model]).map { row in
                let dim: Int = row["dim"]
                return (row["hash"], row["takenAtMs"], Self.unpackFloat16(row["vector"], dim: dim))
            }
        }
    }
```

- [ ] **Step 6: Add the `eligibleKind` case** in `Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift` — inside `eligibleKind(forStage:)`, add `case "phash": return "photo"` alongside the others.

- [ ] **Step 7: Create `Sources/OpenPhotoCore/Derivation/PHashStage.swift`:**

```swift
import Foundation

/// Background derivation: a perceptual hash (dHash) per photo for near-duplicate detection.
/// Needs the image bytes (`needsFile == true`); always available (no model). Mirrors GeocodeStage.
public final class PHashStage: @unchecked Sendable {
    public let id = "phash"
    public let eligibleKind = "photo"
    public init() {}
}

extension PHashStage: DerivationStage {
    public func run(hash: String, url: URL, catalog: Catalog) async -> Bool {
        guard let value = PerceptualHash.compute(imageAt: url) else { return false }
        try? catalog.upsertPHash(hash: hash, value: value)
        return true
    }
}
```

- [ ] **Step 8: Run + clean build** — `swift test --filter "schemaIsV10|phash|embeddingsWithTakenAt|pendingDerivationIncludesPhotosForPhash" 2>&1 | tail -8` → all pass. `swift test 2>&1 | tail -3` → full suite green. Both warning greps empty.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Sources/OpenPhotoCore/Catalog/Catalog+PHash.swift Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift Sources/OpenPhotoCore/Derivation/PHashStage.swift Tests/OpenPhotoCoreTests/PHashStageTests.swift
git commit -m "$(cat <<'EOF'
feat(cull): phash table (migration v10) + PHashStage derivation

A new rebuildable `phash` table (catalog migration v10, schemaVersion 9→10) holds a 64-bit
dHash per photo; PHashStage computes it in the background drain like OCR/Embed/Faces/Geocode.
Catalog+PHash.phashRowsWithDirPath joins the timeline union (local ∪ drive-only) for same-folder
duplicate grouping; embeddingsWithTakenAt feeds burst grouping. No sidecar, no vault-format change.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `BurstGrouper` + `DuplicateGrouper` + `KeeperSelector`

**Files:** Create `Sources/OpenPhotoCore/Cull/BurstGrouper.swift`, `Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift`, `Sources/OpenPhotoCore/Cull/KeeperSelector.swift`, `Tests/OpenPhotoCoreTests/CullGrouperTests.swift`.

- [ ] **Step 1: Write the failing tests** — `Tests/OpenPhotoCoreTests/CullGrouperTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func burstGroupsByTimeAndSimilarity() {
    // a,b,c near-identical within 10s → one burst; d is similar but 1h later → its own (dropped);
    // e is within time but dissimilar → not joined.
    let v1: [Float] = [1, 0, 0], v2: [Float] = [0.99, 0.14, 0], vDiff: [Float] = [0, 1, 0]
    let items: [(hash: String, takenAtMs: Int64, vector: [Float])] = [
        ("a", 0, v1), ("b", 2_000, v2), ("c", 5_000, v1),
        ("e", 6_000, vDiff),
        ("d", 3_600_000, v1),
    ]
    let groups = BurstGrouper.group(items, windowMs: 10_000, cosineThreshold: 0.9)
    #expect(groups.count == 1)
    #expect(Set(groups[0]) == ["a", "b", "c"])
}

@Test func duplicateGroupsWithinSameFolderOnly() {
    let items: [(hash: String, dirPath: String, value: Int64)] = [
        ("a", "trip", 0b0000),
        ("b", "trip", 0b0001),       // 1 bit from a → same folder dup
        ("c", "other", 0b0000),      // identical to a but a DIFFERENT folder → not grouped
        ("d", "trip", Int64(bitPattern: ~0)),  // far → not in the group
    ]
    let groups = DuplicateGrouper.group(items, hammingThreshold: 4)
    #expect(groups.count == 1)
    #expect(Set(groups[0]) == ["a", "b"])
}

@Test func duplicateSiblingFolderSafe() {
    let items: [(hash: String, dirPath: String, value: Int64)] = [
        ("a", "2025", 0), ("b", "2025x", 0),  // identical hash, sibling-prefix folders → NOT grouped
    ]
    #expect(DuplicateGrouper.group(items, hammingThreshold: 4).isEmpty)
}

@Test func keeperDuplicatesPrefersHighestResolution() {
    let c = [
        KeeperSelector.Candidate(hash: "small", pixelCount: 1000, fileSize: 50, favorite: false, rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "big",   pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: nil),
    ]
    let s = KeeperSelector.suggestion(c, mode: .duplicates)
    #expect(s.keep == "big")
    #expect(s.evict == ["small"])
}

@Test func keeperBurstsPrefersSharpest() {
    let c = [
        KeeperSelector.Candidate(hash: "blur",  pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: 5),
        KeeperSelector.Candidate(hash: "sharp", pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: 50),
    ]
    let s = KeeperSelector.suggestion(c, mode: .bursts)
    #expect(s.keep == "sharp")
    #expect(s.evict == ["blur"])
}

@Test func keeperProtectsFavoritesAndRated() {
    let c = [
        KeeperSelector.Candidate(hash: "keep", pixelCount: 9000, fileSize: 80, favorite: false, rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "fav",  pixelCount: 1000, fileSize: 10, favorite: true,  rating: 0, sharpness: nil),
        KeeperSelector.Candidate(hash: "rated",pixelCount: 1000, fileSize: 10, favorite: false, rating: 4, sharpness: nil),
        KeeperSelector.Candidate(hash: "drop", pixelCount: 1000, fileSize: 10, favorite: false, rating: 0, sharpness: nil),
    ]
    let s = KeeperSelector.suggestion(c, mode: .duplicates)
    #expect(s.keep == "keep")
    #expect(Set(s.evict) == ["drop"])          // fav + rated never evicted
}
```

- [ ] **Step 2: Run, confirm fail** — `swift test --filter "burst|duplicate|keeper" 2>&1 | tail -5` → "cannot find 'BurstGrouper'".

- [ ] **Step 3: Create `Sources/OpenPhotoCore/Cull/BurstGrouper.swift`:**

```swift
import Foundation

/// Group photos into bursts: sort by capture time, then chain consecutive photos while the gap to
/// the previous ≤ windowMs AND their CLIP cosine ≥ threshold. Vectors are L2-normalized, so cosine
/// is a dot product. Returns groups of ≥ 2 (singletons dropped). Pure + unit-tested.
public enum BurstGrouper {
    public static func group(_ items: [(hash: String, takenAtMs: Int64, vector: [Float])],
                             windowMs: Int64, cosineThreshold: Float) -> [[String]] {
        let sorted = items.sorted { $0.takenAtMs < $1.takenAtMs }
        var groups: [[String]] = []
        var current: [Int] = []
        func flush() { if current.count >= 2 { groups.append(current.map { sorted[$0].hash }) }; current = [] }
        for i in sorted.indices {
            if current.isEmpty { current = [i]; continue }
            let last = current[current.count - 1]
            let gap = sorted[i].takenAtMs - sorted[last].takenAtMs
            if gap <= windowMs && dot(sorted[i].vector, sorted[last].vector) >= cosineThreshold {
                current.append(i)
            } else {
                flush(); current = [i]
            }
        }
        flush()
        return groups
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0; for i in a.indices { s += a[i] * b[i] }; return s
    }
}
```

- [ ] **Step 4: Create `Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift`:**

```swift
import Foundation

/// Group the SAME image saved as separate files. Bucket by exact `dirPath` (sibling-safe — never a
/// prefix), then within each folder union photos whose perceptual-hash Hamming distance ≤ threshold.
/// Cross-folder near-matches are assumed intentional and never grouped. Returns groups with ≥ 2
/// distinct hashes. Pure + unit-tested.
public enum DuplicateGrouper {
    public static func group(_ items: [(hash: String, dirPath: String, value: Int64)],
                             hammingThreshold: Int) -> [[String]] {
        var byFolder: [String: [(hash: String, value: Int64)]] = [:]
        for it in items { byFolder[it.dirPath, default: []].append((it.hash, it.value)) }

        var groups: [[String]] = []
        for (_, rows) in byFolder where rows.count >= 2 {
            var parent = Array(rows.indices)
            func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
            func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
            for i in rows.indices {
                for j in (i + 1)..<rows.count where
                    PerceptualHash.hamming(rows[i].value, rows[j].value) <= hammingThreshold {
                    union(i, j)
                }
            }
            var clusters: [Int: [String]] = [:]
            for i in rows.indices { clusters[find(i), default: []].append(rows[i].hash) }
            for (_, hashes) in clusters where Set(hashes).count >= 2 { groups.append(hashes) }
        }
        return groups
    }
}
```

- [ ] **Step 5: Create `Sources/OpenPhotoCore/Cull/KeeperSelector.swift`:**

```swift
import Foundation

public enum CullMode: Sendable, Equatable { case bursts, duplicates }

/// Pick the suggested keeper for a redundant group and the rejects to pre-select for deletion.
/// Duplicates → highest resolution then largest file; bursts → sharpest then resolution.
/// Favorites & rated photos are NEVER in `evict` (protected — kept, the user can still delete by hand).
public enum KeeperSelector {
    public struct Candidate: Sendable, Equatable {
        public let hash: String
        public let pixelCount: Int
        public let fileSize: Int64
        public let favorite: Bool
        public let rating: Int
        public let sharpness: Double?
        public init(hash: String, pixelCount: Int, fileSize: Int64, favorite: Bool, rating: Int, sharpness: Double?) {
            self.hash = hash; self.pixelCount = pixelCount; self.fileSize = fileSize
            self.favorite = favorite; self.rating = rating; self.sharpness = sharpness
        }
    }

    /// `c` must be non-empty.
    public static func suggestion(_ c: [Candidate], mode: CullMode) -> (keep: String, evict: [String]) {
        precondition(!c.isEmpty)
        // `max(by:)` predicate is "a < b" — return true when `a` should rank BELOW `b`. The final
        // tiebreak `a.hash > b.hash` makes the smallest hash win (deterministic).
        let keep: Candidate = c.max { a, b in
            switch mode {
            case .duplicates:
                if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
                if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
                return a.hash > b.hash
            case .bursts:
                let sa = a.sharpness ?? -1, sb = b.sharpness ?? -1
                if sa != sb { return sa < sb }
                if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
                return a.hash > b.hash
            }
        }!
        let evict = c.filter { $0.hash != keep.hash && !$0.favorite && $0.rating == 0 }.map { $0.hash }
        return (keep.hash, evict)
    }
}
```

- [ ] **Step 6: Run + clean build** — `swift test --filter "burst|duplicate|keeper" 2>&1 | tail -10` → all pass. Both warning greps empty.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoCore/Cull/BurstGrouper.swift Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift Sources/OpenPhotoCore/Cull/KeeperSelector.swift Tests/OpenPhotoCoreTests/CullGrouperTests.swift
git commit -m "$(cat <<'EOF'
feat(cull): pure BurstGrouper + DuplicateGrouper + KeeperSelector

BurstGrouper chains time-adjacent photos above a cosine threshold (L2-normalized → dot).
DuplicateGrouper buckets by exact dirPath (sibling-safe) and unions same-folder photos within a
pHash Hamming threshold (≥2 distinct hashes). KeeperSelector: duplicates→resolution, bursts→
sharpness; favorites/rated never in the evict set. The thoroughly-tested heart.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `AppState` cull state + `Tidy Up` sidebar wiring

**Files:** Modify `Sources/OpenPhotoApp/AppState.swift`, `Sources/OpenPhotoApp/OpenPhotoApp.swift`.

- [ ] **Step 1: Add the sidebar case** in `AppState.swift`'s `enum SidebarItem` (line ~6): add `tidyUp` to the `case` list, and a `label` (`case .tidyUp: "Tidy Up"`) + `symbol` (`case .tidyUp: "square.on.square"`).

- [ ] **Step 2: Register the stage** — in `AppState.swift`, the `derivationStages` array, append `PHashStage()`:
```swift
    private let derivationStages: [any DerivationStage] =
        [OCRDerivationStage(), EmbedStage(), FaceDerivationStage(), GeocodeStage(), PHashStage()]
```

- [ ] **Step 3: Add cull state + loader** — in `AppState.swift` (a new `// MARK: — Tidy Up (cull)` section), add:
```swift
    struct CullGroup: Identifiable {
        let id: String                 // the keeper hash
        let items: [TimelineItem]
        let keep: String
        let suggestedEvict: Set<String>
    }
    var cullMode: CullMode = .bursts
    var cullGroups: [CullGroup] = []
    var cullLoading = false

    /// Compute redundant-photo groups off-main (the loadPeople pattern). Bursts reuse `embeddings`;
    /// Duplicates use the `phash` table. Sharpness (bursts) is measured on-demand from cached thumbs.
    func loadCullGroups() {
        guard let lib = library else { return }
        let mode = cullMode
        cullLoading = true
        Task {
            let groups: [CullGroup] = await Task.detached(priority: .userInitiated) {
                let raw: [[String]]
                switch mode {
                case .bursts:
                    let items = (try? lib.catalog.embeddingsWithTakenAt(model: EmbedStage().modelID)) ?? []
                    raw = BurstGrouper.group(items, windowMs: 60_000, cosineThreshold: 0.93)
                case .duplicates:
                    let rows = (try? lib.catalog.phashRowsWithDirPath()) ?? []
                    raw = DuplicateGrouper.group(rows, hammingThreshold: 6)
                }
                var out: [CullGroup] = []
                for g in raw {
                    let items = (try? lib.catalog.items(forHashes: g, preservingOrder: true)) ?? []
                    guard items.count >= 2 else { continue }
                    var cands: [KeeperSelector.Candidate] = []
                    for it in items {
                        var sharp: Double? = nil
                        if mode == .bursts,
                           let img = await lib.thumbnails.cachedDisplayImage(
                               for: ContentHash(stringValue: it.hash), maxPixel: ThumbnailStore.maxPixel) {
                            sharp = FocusMeasure.varianceOfLaplacian(img)
                        }
                        cands.append(.init(hash: it.hash,
                                           pixelCount: (it.pixelWidth ?? 0) * (it.pixelHeight ?? 0),
                                           fileSize: it.size, favorite: it.favorite,
                                           rating: it.rating, sharpness: sharp))
                    }
                    let s = KeeperSelector.suggestion(cands, mode: mode)
                    out.append(CullGroup(id: s.keep, items: items, keep: s.keep,
                                         suggestedEvict: Set(s.evict)))
                }
                return out
            }.value
            self.cullGroups = groups
            self.cullLoading = false
        }
    }
```
> `TimelineItem` exposes `hash`, `pixelWidth: Int?`, `pixelHeight: Int?`, `size: Int64`, `favorite: Bool`, `rating: Int` (confirm by reading `TimelineItem`); `lib.thumbnails` is the `ThumbnailStore`; `ContentHash(stringValue:)` + `ThumbnailStore.maxPixel` already exist.

- [ ] **Step 4: Add the detail arm** in `Sources/OpenPhotoApp/OpenPhotoApp.swift`'s `detail` switch: `case .tidyUp: CleanupView(state: state)`. (CleanupView lands in Task 5; to keep this task compiling on its own, add a one-line placeholder `struct CleanupView: View { @Bindable var state: AppState; var body: some View { Color.clear } }` in `OpenPhotoApp.swift` *only if needed to build*, to be replaced in Task 5 — OR sequence Task 5 immediately and build them together. Prefer: add the arm now and the real `CleanupView` in Task 5; if the build fails for the missing type, add the placeholder and delete it in Task 5.)

- [ ] **Step 5: Build, zero warnings** — `swift build 2>&1 | grep -i warning` → empty. `swift build --build-tests 2>&1 | grep -i warning` → empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat(cull): AppState Tidy Up state + loadCullGroups + PHashStage in the registry

SidebarItem.tidyUp; cullMode/cullGroups/cullLoading + an off-main loadCullGroups that runs the
pure groupers (bursts reuse embeddings; duplicates use the phash table) and KeeperSelector,
measuring burst sharpness from cached thumbnails. PHashStage joins the derivation registry.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `CleanupView` (the Tidy Up surface)

**Files:** Create `Sources/OpenPhotoApp/Cleanup/CleanupView.swift` (replace any placeholder added in Task 4).

**Context for the implementer:** Follow the existing view patterns — `PeopleView` (toolbar + grouped grid + off-main load on appear), `TimelineView`'s `cell(_:)` (the `MediaTile` + `ThumbnailImage(timelineItem:library:targetPixel:)` usage), and `SelectionUI.swift` (`SelectionModel`, `RubberBandModifier`, `SelectionActionBar`). Deletion uses `state.delete([items])` (already on `AppState`). Reload via `state.loadCullGroups()`.

- [ ] **Step 1: Build the view.** `CleanupView` requirements:
  - **Toolbar:** title "Tidy Up"; a **Bursts / Duplicates** segmented `Picker` bound to `$state.cullMode` (`.onChange` → `state.loadCullGroups()`); a group-count label; a `ProgressView` while `state.cullLoading`.
  - **On appear:** `state.loadCullGroups()`.
  - **Body:** a `ScrollView` of **group rows**. Each `CullGroup` renders a labeled row (e.g. "5 similar · keeping the sharpest") and a horizontal `LazyVGrid`/`HStack` of `MediaTile`s — one per `group.items` — using `ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: …)`. The **keeper** tile (`group.keep`) gets a distinct ring/badge ("Keep"); tiles in `group.suggestedEvict` start **selected**.
  - **Selection:** a single shared `SelectionModel` across the whole surface (ids = `instanceID`), seeded from every group's `suggestedEvict` on load; tap toggles, shift-range + rubber-band via the existing modifier. Keeper tiles are selectable too (the user may override).
  - **Action bar** (shown when selection non-empty): "**Delete N**" → confirm → `await state.delete(selectedItems)` then `state.loadCullGroups()`; "**Apply all suggestions**" → delete every group's `suggestedEvict` across all groups; "Deselect". Deletion is the recoverable bin path.
  - **Empty state:** when `cullGroups` is empty and not loading — "Nothing to tidy up" with a short hint that analysis may still be running (bursts need embeddings; duplicates need the phash backfill).
  - Match `Theme` styling; no warnings; no dead code.

- [ ] **Step 2: Build + zero warnings + rebuild bundle** — `swift build 2>&1 | grep -i warning; swift build --build-tests 2>&1 | grep -i warning` → empty. `./scripts/make-app.sh 2>&1 | tail -2` → "Built build/OpenPhoto.app".

- [ ] **Step 3: Manual smoke (implementer notes; user runs):** Tidy Up appears in the sidebar; the Bursts/Duplicates toggle reloads; groups render with the keeper ringed and rejects pre-selected; multi-select adjusts; Delete N / Apply all move photos to the Bin (recoverable).

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Cleanup/CleanupView.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "$(cat <<'EOF'
feat(cull): Tidy Up surface — grouped MediaTile rows, multi-select, recoverable delete

A dedicated review surface with a Bursts/Duplicates toggle. Each redundant group is a row of the
shared MediaTile with the suggested keeper ringed and the rejects pre-selected; the shared
SelectionModel (rubber-band + shift) adjusts keep vs delete. Delete N / Apply all suggestions use
the existing recoverable bin path. Bundle rebuilt.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Docs — `catalog-schema.md` v10 + master spec DONE

**Files:** Modify `docs/format/catalog-schema.md`, `docs/superpowers/specs/2026-06-07-openphoto-design.md`.

- [ ] **Step 1: `catalog-schema.md`** — bump the title/version to **Version 10**; add a `phash` table section (columns `hash` TEXT PK → assets.hash, `value` INTEGER = 64-bit dHash) described as a **rebuildable, machine-derived, droppable cache** (a deterministic dHash of the image; external readers MAY ignore it); add it to the Portability key + Versioning notes. No `vault-format-v1.md` change.

- [ ] **Step 2: master spec** — in §10.5, change the **near-duplicate / burst culling** bullet's lead to **DONE**, and append a changelog entry:

```markdown
- **2026-06-11** — **Phase 5 — near-duplicate / burst culling (DONE).** A dedicated **Tidy Up**
  surface with two modes: **Bursts** (time-window + CLIP-cosine grouping over the existing
  `embeddings`, keeper = sharpest via on-demand variance-of-Laplacian) and **Duplicates** (a new
  64-bit perceptual `dHash` per photo — `PHashStage` → rebuildable `phash` table, **catalog
  migration v10** — grouped within the **same folder**, keeper = highest resolution). Pure
  unit-tested groupers + keeper (`BurstGrouper`/`DuplicateGrouper`/`KeeperSelector`); favorites/rated
  protected; deletion reuses the recoverable bin path. **Catalog-only, no vault-format change**
  (`catalog-schema.md` → v10). Spec/plan: `docs/superpowers/specs/2026-06-11-near-dup-culling-design.md`,
  `docs/superpowers/plans/2026-06-11-near-dup-culling.md`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/format/catalog-schema.md docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: catalog-schema v10 (phash table) + near-dup culling DONE in master spec

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (plan author)

- **Spec coverage:** §2 PerceptualHash/FocusMeasure → T1; phash table+stage+queries → T2; BurstGrouper/DuplicateGrouper/KeeperSelector → T3; AppState+sidebar → T4; CleanupView → T5; docs → T6. Modes, same-folder rule, keeper heuristics, favorites-protected, on-demand grouping, drive-only coverage, recoverable delete — all covered. ✓
- **Placeholder scan:** complete code in every Core step; SQL/tests concrete; App tasks give exact bindings + reference real patterns. No "TBD". ✓
- **Type consistency:** `PerceptualHash.compute/dHash/hamming`, `FocusMeasure.varianceOfLaplacian`, `phash(hash,value)`, `phashRowsWithDirPath`, `embeddingsWithTakenAt`, `PHashStage`, `BurstGrouper.group`, `DuplicateGrouper.group`, `KeeperSelector.Candidate/suggestion`, `CullMode`, `AppState.CullGroup/cullMode/cullGroups/loadCullGroups`, `SidebarItem.tidyUp`, `CleanupView` — names consistent across tasks and against the real APIs (`upsertEmbedding`, `items(forHashes:preservingOrder:)`, `cachedDisplayImage(for:maxPixel:)`, `ThumbnailStore.maxPixel`, `delete(_:)`). ✓
- **Ordering:** T2 depends on T1 (`PerceptualHash`), T3 on T1, T4 on T2+T3, T5 on T4. Execute T1→T6 in order. ✓
