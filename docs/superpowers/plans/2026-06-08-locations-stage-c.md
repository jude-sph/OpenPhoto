# Locations / Presence (Stage C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a "Locations" view — for the selected photo, show everywhere OpenPhoto knows it exists (This Mac / phones / SD cards) with confidence + recency — and upgrade the evict only-copy warning to use that full presence.

**Architecture:** A catalog-derived `PresenceService` (Core) aggregates, per content hash: This Mac (from the catalog — *confirmed*), devices we've sent it to (`sends.jsonl` — *believed*), and devices it was imported from (`imports.jsonl` — *historical*). The eviction "only copy" judgment counts confirmed/believed copies but NOT historical (an SD card it once came from may have been wiped). The inspector's placeholder "Presence" section is replaced with the real panel. Forward-compatible: Phase-3 drive presence slots in as more `confirmed` device rows.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM, Swift Testing, GRDB.

**Spec:** `docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md` (Stage C, §4.7/§6.2/§6.4). **Builds on** Stage A (BackupProbe/`AppState.onlyCopyCount`, which this upgrades), B1/B2 (`SendRegistry`/`DeviceRegistry`, `DeviceKind`). Final stage.

---

## Conventions for every task
- **Build:** `swift build` — zero warnings. **Test:** `swift test` / `--filter <name>`. **Run:** `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
- Never touch real user folders — generated fixtures only. TDD for Core (Tasks 1–2); build for App (Tasks 3–4). Commit each task with the exact message.

## File structure
**Modify (Core, tested):** `Sources/OpenPhotoCore/Catalog/Queries.swift` (+`instances(forHash:)`), `Sources/OpenPhotoCore/Import/ImportRegistry.swift` (+`entries(forHash:)`), `Sources/OpenPhotoCore/Send/SendRegistry.swift` (+`entries(forHash:)`).
**Create (Core, tested):** `Sources/OpenPhotoCore/Presence/PresenceService.swift` (+ `Location` types).
**Modify (App):** `Sources/OpenPhotoApp/AppState.swift` (`locations(for:)`, switch `onlyCopyCount` to PresenceService). `Sources/OpenPhotoApp/Inspector/InspectorView.swift` (real Presence section).

---

## Task 1: Presence queries (by-hash lookups)

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Queries.swift`, `Sources/OpenPhotoCore/Import/ImportRegistry.swift`, `Sources/OpenPhotoCore/Send/SendRegistry.swift`
- Test: `Tests/OpenPhotoCoreTests/PresenceQueriesTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/OpenPhotoCoreTests/PresenceQueriesTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func catalogInstancesForHashReturnsLocalInstances() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let hash = try #require(try lib.catalog.timelineItems().first).hash
    let instances = try lib.catalog.instances(forHash: hash)
    #expect(instances.count == 1)
    #expect(instances[0].relPath == "rome/IMG_1.jpg" && instances[0].dirPath == "rome")
    #expect(try lib.catalog.instances(forHash: "sha256:" + String(repeating: "0", count: 64)).isEmpty)
}

@Test func registryEntriesForHash() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let h = "sha256:" + String(repeating: "a", count: 64)
    let imports = ImportRegistry(vault: vault)
    try imports.append(ImportRegistry.Entry(sourceKey: "vol-Y", name: "x.jpg", size: 1, takenAt: "",
        hash: h, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/x.jpg"))
    #expect(imports.entries(forHash: h).count == 1)
    #expect(imports.entries(forHash: "sha256:" + String(repeating: "b", count: 64)).isEmpty)

    let sends = SendRegistry(vault: vault)
    try sends.append(SendRegistry.Entry(hash: h, destinationKey: "cam-Z", deviceName: "iPhone",
        deviceKind: "phone", sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: 1, fpCaptureDateMs: 0))
    #expect(sends.entries(forHash: h).count == 1)
    #expect(sends.entries(forHash: "sha256:" + String(repeating: "b", count: 64)).isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails.** `swift test --filter catalogInstancesForHashReturnsLocalInstances` → "has no member 'instances'".

- [ ] **Step 3: Implement the three queries.**

(a) In `Sources/OpenPhotoCore/Catalog/Queries.swift`, inside the `extension Catalog`, add (near `instanceItem(hash:vaultID:)`):
```swift
    /// All local instances of an asset (across vaults) — for presence/Locations.
    public func instances(forHash hash: String) throws -> [InstanceRecord] {
        try dbQueue.read { db in
            try InstanceRecord.fetchAll(db, sql: "SELECT * FROM instances WHERE hash = ?",
                                        arguments: [hash])
        }
    }
```

(b) In `Sources/OpenPhotoCore/Import/ImportRegistry.swift`, after `entries(forSourceKey:)`, add:
```swift
    /// All import entries that recorded these exact bytes (any device).
    public func entries(forHash hash: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.hash == hash }
    }
```

(c) In `Sources/OpenPhotoCore/Send/SendRegistry.swift`, after `entries(forDestinationKey:)`, add:
```swift
    /// All confirmed-send entries for these exact bytes (any device).
    public func entries(forHash hash: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.hash == hash }
    }
```

- [ ] **Step 4: Run the tests.** `swift test --filter "catalogInstancesForHashReturnsLocalInstances|registryEntriesForHash"` (pass), then `swift test` (full green — 97).

- [ ] **Step 5: Commit.**
```bash
git add Sources/OpenPhotoCore/Catalog/Queries.swift Sources/OpenPhotoCore/Import/ImportRegistry.swift Sources/OpenPhotoCore/Send/SendRegistry.swift Tests/OpenPhotoCoreTests/PresenceQueriesTests.swift
git commit -m "$(cat <<'EOF'
feat: by-hash presence queries (catalog instances + registry entries)

Catalog.instances(forHash:), ImportRegistry.entries(forHash:), and
SendRegistry.entries(forHash:) — the lookups PresenceService aggregates
into a photo's locations.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PresenceService + Location types

**Files:**
- Create: `Sources/OpenPhotoCore/Presence/PresenceService.swift`
- Test: `Tests/OpenPhotoCoreTests/PresenceServiceTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/OpenPhotoCoreTests/PresenceServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func presenceLocationsAndOnlyCopyJudgment() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("a/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: nil, lon: nil)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()
    let vault = lib.vaults.first!
    let hash = try #require(try lib.catalog.timelineItems().first).hash
    let imports = ImportRegistry(vault: vault), sends = SendRegistry(vault: vault)
    let devices = DeviceRegistry(vault: vault)
    let presence = PresenceService(catalog: lib.catalog, imports: imports, sends: sends, devices: devices)

    // Only on this Mac initially.
    #expect(presence.isOnlyOnThisMac(hash: hash))
    let locs0 = presence.locations(forHash: hash)
    #expect(locs0.contains { if case .thisMac = $0.place { $0.confidence == .confirmed } else { false } })

    // After a confirmed send → backed up (believed), no longer only-copy.
    try sends.append(SendRegistry.Entry(hash: hash, destinationKey: "cam-Z", deviceName: "iPhone",
        deviceKind: "phone", sentAt: "2026-06-08T01:00:00.000Z", confirmedAt: "2026-06-08T01:01:00.000Z",
        fpSize: 1, fpCaptureDateMs: 0))
    #expect(!presence.isOnlyOnThisMac(hash: hash))
    #expect(presence.locations(forHash: hash).contains {
        if case .device(_, let n, let k) = $0.place { n == "iPhone" && k == .phone && $0.confidence == .believed }
        else { false } })

    // A hash that was only IMPORTED FROM a device (historical) is still only-copy:
    // a card it came from may have been wiped — history doesn't count as backup.
    let h2 = "sha256:" + String(repeating: "e", count: 64)
    try imports.append(ImportRegistry.Entry(sourceKey: "vol-Y", name: "x.jpg", size: 1, takenAt: "",
        hash: h2, importedAt: "2026-06-08T00:00:00.000Z", importedTo: "a/x.jpg"))
    #expect(presence.isOnlyOnThisMac(hash: h2))
    #expect(presence.locations(forHash: h2).contains {
        if case .device = $0.place { $0.confidence == .historical } else { false } })
}
```

- [ ] **Step 2: Run to verify it fails.** `swift test --filter presenceLocationsAndOnlyCopyJudgment` → "cannot find 'PresenceService' in scope".

- [ ] **Step 3: Implement.** Create `Sources/OpenPhotoCore/Presence/PresenceService.swift`:

```swift
import Foundation

/// One known location of an asset, with how sure we are and when we last knew.
public struct Location: Sendable, Equatable, Identifiable {
    public enum Place: Sendable, Equatable {
        case thisMac
        case device(key: String, name: String, kind: DeviceKind)
    }
    /// confirmed = present right here / seen on connect; believed = we sent it and
    /// verified it landed but haven't re-checked since; historical = it was once on
    /// a device (e.g. imported from) — may be gone now.
    public enum Confidence: String, Sendable { case confirmed, believed, historical }
    public let place: Place
    public let confidence: Confidence
    public let detail: String
    public init(place: Place, confidence: Confidence, detail: String) {
        self.place = place; self.confidence = confidence; self.detail = detail
    }
    public var id: String {
        switch place {
        case .thisMac: return "mac"
        case .device(let key, _, _): return "dev:\(key):\(confidence.rawValue)"
        }
    }
}

/// Catalog-derived "where is this photo?" view (spec §4.7). Rebuildable; reads the
/// catalog + the import/send/device registries. Supersedes Stage A's BackupProbe
/// for the eviction only-copy judgment.
public struct PresenceService: Sendable {
    private let catalog: Catalog
    private let imports: ImportRegistry
    private let sends: SendRegistry
    private let devices: DeviceRegistry

    public init(catalog: Catalog, imports: ImportRegistry, sends: SendRegistry, devices: DeviceRegistry) {
        self.catalog = catalog; self.imports = imports; self.sends = sends; self.devices = devices
    }

    /// All known locations of an asset, This-Mac first, then sent-to, then came-from.
    public func locations(forHash hash: String) -> [Location] {
        var out: [Location] = []
        var seenDevices = Set<String>()

        // This Mac (confirmed) — from the catalog.
        if let instances = try? catalog.instances(forHash: hash), !instances.isEmpty {
            let folders = Set(instances.map { $0.dirPath.isEmpty ? "(root)" : $0.dirPath })
            out.append(Location(place: .thisMac, confidence: .confirmed,
                                detail: folders.sorted().joined(separator: ", ")))
        }

        // Sent to devices (believed) — confirmed at send time, not re-checked since.
        for e in sends.entries(forHash: hash) where !seenDevices.contains(e.destinationKey) {
            seenDevices.insert(e.destinationKey)
            let name = devices.name(forKey: e.destinationKey) ?? e.deviceName
            out.append(Location(place: .device(key: e.destinationKey, name: name,
                                               kind: DeviceKind(rawValue: e.deviceKind) ?? kind(forKey: e.destinationKey)),
                                confidence: .believed, detail: "sent " + day(e.confirmedAt)))
        }

        // Imported from devices (historical) — may be gone now.
        for e in imports.entries(forHash: hash) where !seenDevices.contains(e.sourceKey) {
            seenDevices.insert(e.sourceKey)
            let name = devices.name(forKey: e.sourceKey) ?? e.sourceKey
            out.append(Location(place: .device(key: e.sourceKey, name: name, kind: kind(forKey: e.sourceKey)),
                                confidence: .historical, detail: "imported " + day(e.importedAt)))
        }
        return out
    }

    /// True when no copy is known on any device with confidence confirmed/believed
    /// (historical "came from" doesn't count — that card may have been wiped).
    public func isOnlyOnThisMac(hash: String) -> Bool {
        !locations(forHash: hash).contains { loc in
            if case .device = loc.place { return loc.confidence == .confirmed || loc.confidence == .believed }
            return false
        }
    }

    /// Subset of `hashes` that appear to exist only on this Mac.
    public func onlyOnThisMac(hashes: [String]) -> [String] {
        Array(Set(hashes)).filter(isOnlyOnThisMac)
    }

    private func kind(forKey key: String) -> DeviceKind { key.hasPrefix("cam-") ? .phone : .volume }
    private func day(_ iso: String) -> String { String(iso.prefix(10)) }   // YYYY-MM-DD
}
```

- [ ] **Step 4: Run the test.** `swift test --filter presenceLocationsAndOnlyCopyJudgment` (pass), then `swift test` (full green — 98).

- [ ] **Step 5: Commit.**
```bash
git add Sources/OpenPhotoCore/Presence/PresenceService.swift Tests/OpenPhotoCoreTests/PresenceServiceTests.swift
git commit -m "$(cat <<'EOF'
feat: PresenceService — where is this photo (This Mac / sent / imported)

Aggregates catalog + send/import/device registries into per-hash locations
with confidence (confirmed/believed/historical). The only-copy judgment
counts confirmed/believed copies, not historical came-from — superseding
BackupProbe for the eviction warning.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: AppState — locations(for:) + onlyCopyCount via PresenceService

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add `presenceService` + `locations(for:)`, and switch `onlyCopyCount`.**

In `Sources/OpenPhotoApp/AppState.swift`, add a helper to build a PresenceService and a locations accessor, and replace the existing `onlyCopyCount(_:)` (Stage A, which used `BackupProbe`) to use PresenceService.

Add these methods (next to the existing `onlyCopyCount`/`evict`):
```swift
    /// PresenceService over the current registries, if a library is open.
    private func presenceService() -> PresenceService? {
        guard let library, let imports = importRegistry,
              let sends = sendRegistry, let devices = deviceRegistry else { return nil }
        return PresenceService(catalog: library.catalog, imports: imports, sends: sends, devices: devices)
    }

    /// Known locations of a photo (This Mac / phones / SD cards) for the inspector.
    func locations(for item: TimelineItem) -> [Location] {
        presenceService()?.locations(forHash: item.hash) ?? []
    }
```

Then REPLACE the existing `onlyCopyCount(_:)` method body with the PresenceService-backed version:
```swift
    /// How many of `items` appear to exist only on this Mac (no confirmed/believed
    /// copy elsewhere). No presence info yet → treat all as only-copies.
    func onlyCopyCount(_ items: [TimelineItem]) -> Int {
        guard let presence = presenceService() else { return Set(items.map(\.hash)).count }
        return presence.onlyOnThisMac(hashes: items.map(\.hash)).count
    }
```

(If `BackupProbe` is now unused anywhere else in the app, that's fine — leave the Core type in place; it remains covered by its own tests. Do not delete it.)

- [ ] **Step 2: Build.** `swift build` → zero warnings.

- [ ] **Step 3: Commit.**
```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "$(cat <<'EOF'
feat: AppState locations(for:) + presence-backed only-copy count

Adds locations(for:) for the inspector and upgrades onlyCopyCount to use
PresenceService (sent-to counts as backed up; imported-from history does
not), superseding the Stage-A BackupProbe path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Locations panel in the inspector

**Files:**
- Modify: `Sources/OpenPhotoApp/Inspector/InspectorView.swift`

- [ ] **Step 1: Replace the placeholder Presence section.** In `Sources/OpenPhotoApp/Inspector/InspectorView.swift`, find the existing block:

```swift
                section("Presence") {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer")
                        Text("This Mac").font(.system(size: 12.5))
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                    }
                    // Drive rows arrive in Phase 3 with the presence map UI.
                }
```

Replace it with a real, data-driven section:

```swift
                section("Locations") {
                    let locations = state.locations(for: item)
                    if locations.isEmpty {
                        Text("Only on this Mac")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    } else {
                        ForEach(locations) { loc in
                            locationRow(loc)
                        }
                    }
                }
```

And add these helper methods to `InspectorView` (e.g. right after the `exifGrid` computed property):

```swift
    @ViewBuilder private func locationRow(_ loc: Location) -> some View {
        HStack(spacing: 8) {
            Image(systemName: locationSymbol(loc.place))
                .foregroundStyle(Theme.textDim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(locationName(loc.place)).font(.system(size: 12.5))
                if !loc.detail.isEmpty {
                    Text(loc.detail).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            confidenceBadge(loc.confidence)
        }
    }

    private func locationSymbol(_ place: Location.Place) -> String {
        switch place {
        case .thisMac: return "laptopcomputer"
        case .device(_, _, let kind): return kind == .phone ? "iphone" : "sdcard"
        }
    }
    private func locationName(_ place: Location.Place) -> String {
        switch place {
        case .thisMac: return "This Mac"
        case .device(_, let name, _): return name
        }
    }
    @ViewBuilder private func confidenceBadge(_ c: Location.Confidence) -> some View {
        switch c {
        case .confirmed:
            Image(systemName: "checkmark").foregroundStyle(Theme.green)
        case .believed:
            Text("sent").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.blue)
        case .historical:
            Text("was here").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
    }
```

- [ ] **Step 2: Build.** `swift build` → zero warnings.

- [ ] **Step 3: Smoke test.** `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app` → open a photo → inspector shows a **Locations** section: "This Mac · \<folder\>" with a green check. (Devices appear once you've sent to / imported from them.)

- [ ] **Step 4: Commit.**
```bash
git add Sources/OpenPhotoApp/Inspector/InspectorView.swift
git commit -m "$(cat <<'EOF'
feat: inspector Locations panel — where this photo is stored

Replaces the placeholder Presence row with a data-driven Locations section:
This Mac (folder) plus any devices it's been sent to (believed) or imported
from (historical), each with a confidence badge.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification
- [ ] `swift build` — zero warnings. `swift test` — full suite green (was 95; now +3 → 98).
- [ ] Smoke: open a photo → **Locations** shows "This Mac". Evict a photo with no known backup → the only-copy warning still fires (now via PresenceService). After sending a photo to a device, its inspector lists that device under Locations.

## Self-review (completed while writing)
- **Spec coverage (Stage C):** PresenceService (§4.7) → Tasks 1–2; Locations inspector panel (§6.4) → Task 4; evict warning upgraded to full presence (§6.2) → Task 3 (`onlyCopyCount` now via PresenceService — historical came-from no longer counts as backup, which is the spec's confidence model). Phase-3 drives slot in as additional confirmed device rows later (out of scope, noted).
- **Type consistency:** `Catalog.instances(forHash:) -> [InstanceRecord]`; `ImportRegistry.entries(forHash:)`/`SendRegistry.entries(forHash:) -> [Entry]`; `Location(place:confidence:detail:)` with `Place{thisMac, device(key:name:kind:)}` + `Confidence{confirmed,believed,historical}`; `PresenceService(catalog:imports:sends:devices:)` `.locations(forHash:)`/`.isOnlyOnThisMac(hash:)`/`.onlyOnThisMac(hashes:)`; `AppState.locations(for:)`/`onlyCopyCount(_:)`. Consistent across tasks.
- **No placeholders:** every step has complete code; the inspector section is replaced in full.
- **Behavior change (intentional):** Stage A's `onlyCopyCount` treated *imported-from* as backed up; Stage C correctly treats it as historical (not a backup), so the only-copy warning becomes appropriately more conservative — matching the spec's confidence model and the bin-is-recoverable safety story.
