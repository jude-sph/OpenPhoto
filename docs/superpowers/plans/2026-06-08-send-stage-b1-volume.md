# Send Pipeline + Volume Transport (Stage B1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the full library→device send pipeline (engine, registries, two-layer dedup, tracking) and a working **volume/SD-card** transport with a "Send to device" UI — everything except the AirDrop/iPhone transport (Stage B2).

**Architecture:** A `SendDestination` protocol (Core) with a fully testable `VolumeCopyDestination`. A `SendEngine` orchestrates: remember the device → live-dedup against what's on the target → send → record confirmed sends in `sends.jsonl` → log. `devices.jsonl` records device friendly-names. All logic is unit-tested with a `FakeSendDestination`; the UI is build-and-smoke. Stage B2 adds an `AirDropDestination` that plugs into the same engine/UI.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (Command Line Tools), Swift Testing, GRDB.

**Spec:** `docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md` (Stage B). **Builds on Stage A** (`SelectionModel`, shared selection UI incl. `SelectionActionBar`, `AppState.evict`, `LibraryService`). Stage B2 (AirDrop + labels) and Stage C (Locations) follow.

---

## Conventions for every task

- **Build:** `swift build` — zero warnings.
- **Test (specific):** `swift test --filter <testFunctionName>` · **Full:** `swift test` (must stay green; 84 today).
- **Run the app (smoke):** `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
- **Never** touch real user folders — fixtures are generated mock files in temp dirs (`TestDirs`, `makeJPEG`).
- TDD for Core tasks (1–5); doc task (6) and App tasks (7–8) are implement → build (0 warnings) → (smoke) → commit.
- Commit each task with the exact message given.

## File structure

**Create (Core, tested):**
- `Sources/OpenPhotoCore/Send/SendDestination.swift` — protocol + value types (`DeviceKind`, `PresenceFingerprint`, `SendItem`, `SendOutcome`, `SendProgress`, `SendDestination`).
- `Sources/OpenPhotoCore/Send/SendRegistry.swift` — `sends.jsonl` (confirmed sends).
- `Sources/OpenPhotoCore/Send/DeviceRegistry.swift` — `devices.jsonl` (known devices).
- `Sources/OpenPhotoCore/Send/SendEngine.swift` — orchestration + two-layer dedup.
- `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift` — filesystem transport.
- `Tests/OpenPhotoCoreTests/FakeSendDestination.swift`, plus `SendDestinationTests`, `SendRegistryTests`, `DeviceRegistryTests`, `SendEngineTests`, `VolumeCopyDestinationTests`.

**Create (App, smoke):**
- `Sources/OpenPhotoApp/Send/SendSheet.swift` — progress + result UI for a send.

**Modify:**
- `docs/format/vault-format-v1.md` — new §13 (`sends.jsonl`), §14 (`devices.jsonl`), §9 `send` event.
- `Sources/OpenPhotoApp/AppState.swift` — registries, `sendDestination(for:)`, `connectedSendTarget()`, `sendItem(for:)`, `send(_:to:progress:)`.
- `Sources/OpenPhotoApp/Selection/SelectionUI.swift` — `SelectionActionBar` gains an optional Send button.
- `Sources/OpenPhotoApp/Timeline/TimelineView.swift`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift` — present `SendSheet`.

---

## Task 1: Send core types + `SendDestination` protocol

**Files:**
- Create: `Sources/OpenPhotoCore/Send/SendDestination.swift`
- Test: `Tests/OpenPhotoCoreTests/SendDestinationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/SendDestinationTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func fingerprintLooseMatchIgnoresSubSecondAndHash() {
    let a = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_500, hash: "sha256:aaa")
    let b = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_900, hash: nil)  // same second
    let c = PresenceFingerprint(size: 100, captureDateMs: 1_700_000_001_500, hash: nil)  // next second
    let d = PresenceFingerprint(size: 101, captureDateMs: 1_700_000_000_500, hash: nil)  // diff size
    #expect(a.looselyMatches(b))     // size + same capture second
    #expect(!a.looselyMatches(c))    // different second
    #expect(!a.looselyMatches(d))    // different size
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter fingerprintLooseMatchIgnoresSubSecondAndHash`
Expected: FAIL — "cannot find 'PresenceFingerprint' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Send/SendDestination.swift`:

```swift
import Foundation

/// Kind of target a library asset can be sent to.
public enum DeviceKind: String, Sendable, Codable { case phone, volume }

/// A cheap identity for "is this asset on the target?" — the round-trip-proven
/// fingerprint (size + capture date). `hash` is filled only when computing it is
/// cheap (volumes); phones leave it nil.
public struct PresenceFingerprint: Sendable, Equatable {
    public let size: Int64
    public let captureDateMs: Int64    // epoch ms; 0 if unknown
    public let hash: String?
    public init(size: Int64, captureDateMs: Int64, hash: String? = nil) {
        self.size = size; self.captureDateMs = captureDateMs; self.hash = hash
    }
    /// Same byte size and same capture second (EXIF dates are second-precision, so
    /// compare at second granularity to avoid sub-second drift).
    public func looselyMatches(_ other: PresenceFingerprint) -> Bool {
        size == other.size && captureDateMs / 1000 == other.captureDateMs / 1000
    }
}

/// One library asset queued to send: its content hash (authoritative identity),
/// the read-only original file, its fingerprint, and a display name for progress.
public struct SendItem: Sendable, Equatable {
    public let hash: String
    public let originalURL: URL
    public let fingerprint: PresenceFingerprint
    public let displayName: String
    public init(hash: String, originalURL: URL, fingerprint: PresenceFingerprint, displayName: String) {
        self.hash = hash; self.originalURL = originalURL
        self.fingerprint = fingerprint; self.displayName = displayName
    }
}

/// Per-item result of a send attempt.
public struct SendOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case confirmed, alreadyPresent, unconfirmed, failed }
    public let item: SendItem
    public let status: Status
    public let error: String?
    public init(item: SendItem, status: Status, error: String? = nil) {
        self.item = item; self.status = status; self.error = error
    }
}

/// Progress tick for the UI.
public struct SendProgress: Sendable {
    public enum Stage: String, Sendable { case sending, verifying }
    public let stage: Stage
    public let done: Int
    public let total: Int
    public let currentName: String
    public init(stage: Stage, done: Int, total: Int, currentName: String) {
        self.stage = stage; self.done = done; self.total = total; self.currentName = currentName
    }
}

/// A place library assets can be sent to (write-side mirror of `ImportSource`).
/// Implementations: `VolumeCopyDestination` (filesystem), `AirDropDestination` (Stage B2).
public protocol SendDestination: Sendable {
    var destinationKey: String { get }   // serial / volume UUID — same keyspace as ImportSource.sourceKey
    var displayName: String { get }
    var deviceKind: DeviceKind { get }
    /// What's currently on the target — for dedup and (AirDrop) verification.
    func enumeratePresent() async throws -> [PresenceFingerprint]
    /// Push items; verify before confirming. Reports progress; returns one outcome per item.
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter fingerprintLooseMatchIgnoresSubSecondAndHash` (pass), then `swift test` (full green — 85).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Send/SendDestination.swift Tests/OpenPhotoCoreTests/SendDestinationTests.swift
git commit -m "$(cat <<'EOF'
feat: SendDestination protocol + send value types

PresenceFingerprint (size + capture-second, optional hash), SendItem,
SendOutcome, SendProgress, and the write-side SendDestination protocol —
the foundation for sending library assets to volumes (and later AirDrop).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SendRegistry (`sends.jsonl`)

**Files:**
- Create: `Sources/OpenPhotoCore/Send/SendRegistry.swift`
- Test: `Tests/OpenPhotoCoreTests/SendRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/SendRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func sendEntry(hash: String, dest: String) -> SendRegistry.Entry {
    SendRegistry.Entry(hash: hash, destinationKey: dest, deviceName: "Backup SSD",
                       deviceKind: "volume", sentAt: "2026-06-08T13:30:00.000Z",
                       confirmedAt: "2026-06-08T13:31:00.000Z", fpSize: 100, fpCaptureDateMs: 1_700_000_000_000)
}

@Test func sendRegistryAppendsLooksUpAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = SendRegistry(vault: vault)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try reg.append(sendEntry(hash: h, dest: "vol-ABC"))
    #expect(reg.contains(destinationKey: "vol-ABC", hash: h))
    #expect(!reg.contains(destinationKey: "vol-XYZ", hash: h))   // different device
    #expect(reg.entries(forDestinationKey: "vol-ABC").count == 1)
    // Idempotent per (destination, hash).
    try reg.append(sendEntry(hash: h, dest: "vol-ABC"))
    let reg2 = SendRegistry(vault: vault); try reg2.load()
    #expect(reg2.entries(forDestinationKey: "vol-ABC").count == 1)
    #expect(reg2.contains(destinationKey: "vol-ABC", hash: h))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter sendRegistryAppendsLooksUpAndPersists`
Expected: FAIL — "cannot find 'SendRegistry' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Send/SendRegistry.swift` (mirrors `ImportRegistry`):

```swift
import Foundation

/// Durable record of every asset OpenPhoto has CONFIRMED sending to a device —
/// sends.jsonl in the primary vault's .openphoto/ (vault-format-v1 §13).
public final class SendRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let hash: String
        public let destinationKey: String
        public let deviceName: String
        public let deviceKind: String
        public let sentAt: String
        public let confirmedAt: String
        public let fpSize: Int64
        public let fpCaptureDateMs: Int64
        enum CodingKeys: String, CodingKey {
            case hash, destinationKey = "destination_key", deviceName = "device_name"
            case deviceKind = "device_kind", sentAt = "sent_at", confirmedAt = "confirmed_at"
            case fpSize = "fp_size", fpCaptureDateMs = "fp_capture_date_ms"
        }
        public init(hash: String, destinationKey: String, deviceName: String, deviceKind: String,
                    sentAt: String, confirmedAt: String, fpSize: Int64, fpCaptureDateMs: Int64) {
            self.hash = hash; self.destinationKey = destinationKey; self.deviceName = deviceName
            self.deviceKind = deviceKind; self.sentAt = sentAt; self.confirmedAt = confirmedAt
            self.fpSize = fpSize; self.fpCaptureDateMs = fpCaptureDateMs
        }
        var key: String { "\(destinationKey)|\(hash)" }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("sends.jsonl")
        try? load()
    }

    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
        }
    }

    public func contains(destinationKey: String, hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byKey["\(destinationKey)|\(hash)"] != nil
    }

    public func entries(forDestinationKey key: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byKey.values.filter { $0.destinationKey == key }
    }

    /// Append (idempotent by destination+hash) and rewrite atomically.
    public func append(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        guard byKey[entry.key] == nil else { return }
        byKey[entry.key] = entry
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.confirmedAt < $1.confirmedAt }) {
            out.append(try enc.encode(e)); out.append(0x0A)
        }
        try AtomicFile.write(out, to: url)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter sendRegistryAppendsLooksUpAndPersists` (pass), then `swift test` (full green — 86).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Send/SendRegistry.swift Tests/OpenPhotoCoreTests/SendRegistryTests.swift
git commit -m "$(cat <<'EOF'
feat: SendRegistry (sends.jsonl) — durable confirmed-send record

Mirror of ImportRegistry, keyed by (destination_key, hash); records only
verified sends. Lives in the primary vault's .openphoto/.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: DeviceRegistry (`devices.jsonl`)

**Files:**
- Create: `Sources/OpenPhotoCore/Send/DeviceRegistry.swift`
- Test: `Tests/OpenPhotoCoreTests/DeviceRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/DeviceRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func deviceRegistryUpsertsNameAndPersists() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = DeviceRegistry(vault: vault)
    reg.upsert(key: "vol-ABC", name: "Backup SSD", kind: "volume", at: "2026-06-08T10:00:00.000Z")
    reg.upsert(key: "vol-ABC", name: "Backup SSD (renamed)", kind: "volume", at: "2026-06-09T10:00:00.000Z")
    #expect(reg.name(forKey: "vol-ABC") == "Backup SSD (renamed)")   // latest name wins
    #expect(reg.name(forKey: "vol-NONE") == nil)
    let reloaded = DeviceRegistry(vault: vault)
    #expect(reloaded.name(forKey: "vol-ABC") == "Backup SSD (renamed)")
    // first_seen is preserved across upserts.
    #expect(reloaded.entry(forKey: "vol-ABC")?.firstSeen == "2026-06-08T10:00:00.000Z")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter deviceRegistryUpsertsNameAndPersists`
Expected: FAIL — "cannot find 'DeviceRegistry' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Send/DeviceRegistry.swift`:

```swift
import Foundation

/// Known devices OpenPhoto has seen — devices.jsonl in the primary vault's
/// .openphoto/ (vault-format-v1 §14). Friendly-name source for the UI.
public final class DeviceRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let key: String
        public var name: String
        public let kind: String
        public let firstSeen: String
        public var lastSeen: String
        enum CodingKeys: String, CodingKey {
            case key, name, kind
            case firstSeen = "first_seen", lastSeen = "last_seen"
        }
        public init(key: String, name: String, kind: String, firstSeen: String, lastSeen: String) {
            self.key = key; self.name = name; self.kind = kind
            self.firstSeen = firstSeen; self.lastSeen = lastSeen
        }
    }

    private let url: URL
    private var byKey: [String: Entry] = [:]
    private let lock = NSLock()

    public init(vault: Vault) {
        url = vault.stateDirURL.appendingPathComponent("devices.jsonl")
        try? load()
    }

    public func load() throws {
        lock.lock(); defer { lock.unlock() }
        byKey.removeAll()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain
            && e.code == NSFileReadNoSuchFileError { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let e = try dec.decode(Entry.self, from: line)
            byKey[e.key] = e
        }
    }

    public func name(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]?.name
    }

    public func entry(forKey key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]
    }

    /// Record/refresh a device. Updates name + last_seen; preserves first_seen.
    public func upsert(key: String, name: String, kind: String, at: String) {
        lock.lock(); defer { lock.unlock() }
        if var e = byKey[key] {
            e.name = name; e.lastSeen = at; byKey[key] = e
        } else {
            byKey[key] = Entry(key: key, name: name, kind: kind, firstSeen: at, lastSeen: at)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in byKey.values.sorted(by: { $0.firstSeen < $1.firstSeen }) {
            if let d = try? enc.encode(e) { out.append(d); out.append(0x0A) }
        }
        try? AtomicFile.write(out, to: url)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter deviceRegistryUpsertsNameAndPersists` (pass), then `swift test` (full green — 87).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Send/DeviceRegistry.swift Tests/OpenPhotoCoreTests/DeviceRegistryTests.swift
git commit -m "$(cat <<'EOF'
feat: DeviceRegistry (devices.jsonl) — known-device friendly names

Upsert by stable key (serial / volume UUID); keeps name + last_seen,
preserves first_seen. Friendly-name source for send tracking + UI.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SendEngine + FakeSendDestination

**Files:**
- Create: `Sources/OpenPhotoCore/Send/SendEngine.swift`
- Create: `Tests/OpenPhotoCoreTests/FakeSendDestination.swift`
- Test: `Tests/OpenPhotoCoreTests/SendEngineTests.swift`

- [ ] **Step 1: Write the failing test + fake**

Create `Tests/OpenPhotoCoreTests/FakeSendDestination.swift`:

```swift
import Foundation
@testable import OpenPhotoCore

/// Scriptable SendDestination for engine tests. `present` is returned by
/// enumeratePresent(); `outcomeFor` decides each item's send status (default confirmed).
final class FakeSendDestination: SendDestination, @unchecked Sendable {
    let destinationKey: String
    let displayName: String
    let deviceKind: DeviceKind
    var present: [PresenceFingerprint]
    var outcomeFor: (SendItem) -> SendOutcome.Status
    private(set) var sentItems: [SendItem] = []

    init(key: String = "vol-FAKE", name: String = "Fake", kind: DeviceKind = .volume,
         present: [PresenceFingerprint] = [],
         outcomeFor: @escaping (SendItem) -> SendOutcome.Status = { _ in .confirmed }) {
        self.destinationKey = key; self.displayName = name; self.deviceKind = kind
        self.present = present; self.outcomeFor = outcomeFor
    }
    func enumeratePresent() async throws -> [PresenceFingerprint] { present }
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        sentItems = items
        return items.map { SendOutcome(item: $0, status: outcomeFor($0), error: nil) }
    }
}
```

Create `Tests/OpenPhotoCoreTests/SendEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func libAndVault(_ t: TestDirs) throws -> (LibraryService, Vault) {
    let pics = try t.sub("Pictures")
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    return (lib, lib.vaults.first!)
}

private func item(_ name: String, hash: String, size: Int64 = 100,
                  captureMs: Int64 = 1_700_000_000_000) -> SendItem {
    SendItem(hash: hash, originalURL: URL(fileURLWithPath: "/tmp/\(name)"),
             fingerprint: PresenceFingerprint(size: size, captureDateMs: captureMs, hash: hash),
             displayName: name)
}

@Test func sendEngineRecordsConfirmedAndLogsDevice() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let sends = SendRegistry(vault: vault)
    let devices = DeviceRegistry(vault: vault)
    let dest = FakeSendDestination(key: "vol-A", name: "Card")
    let engine = SendEngine(library: lib, sends: sends, devices: devices)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    let result = await engine.run(destination: dest, items: [item("a.jpg", hash: h1)], vault: vault)
    #expect(result.confirmed.count == 1)
    #expect(sends.contains(destinationKey: "vol-A", hash: h1))      // recorded
    #expect(devices.name(forKey: "vol-A") == "Card")               // device remembered
}

@Test func sendEngineSkipsItemsAlreadyOnTarget() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    // Target already holds h1 (by hash); h2 is new.
    let dest = FakeSendDestination(key: "vol-A",
        present: [PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_000, hash: h1)])
    let engine = SendEngine(library: lib, sends: SendRegistry(vault: vault),
                            devices: DeviceRegistry(vault: vault))
    let h2 = "sha256:" + String(repeating: "2", count: 64)
    let result = await engine.run(destination: dest,
        items: [item("a.jpg", hash: h1), item("b.jpg", hash: h2)], vault: vault)
    #expect(result.alreadyPresent.count == 1)
    #expect(result.confirmed.count == 1)
    #expect(dest.sentItems.map(\.hash) == [h2])                    // only the new one was sent
}

@Test func sendEngineDedupsByFingerprintWhenNoHashOnTarget() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (lib, vault) = try libAndVault(t)
    let h1 = "sha256:" + String(repeating: "1", count: 64)
    // Phone-style present: no hash, but same size + capture second as the item.
    let dest = FakeSendDestination(key: "cam-A", kind: .phone,
        present: [PresenceFingerprint(size: 100, captureDateMs: 1_700_000_000_400, hash: nil)])
    let engine = SendEngine(library: lib, sends: SendRegistry(vault: vault),
                            devices: DeviceRegistry(vault: vault))
    let result = await engine.run(destination: dest, items: [item("a.jpg", hash: h1)], vault: vault)
    #expect(result.alreadyPresent.count == 1)   // matched by size+date despite no hash
    #expect(dest.sentItems.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter sendEngineRecordsConfirmedAndLogsDevice`
Expected: FAIL — "cannot find 'SendEngine' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Send/SendEngine.swift`:

```swift
import Foundation

/// Runs one send batch: remember device → live-dedup → send → record confirmed →
/// log. Spec: docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md §4.4.
public final class SendEngine: Sendable {
    public struct Result: Sendable {
        public var confirmed: [SendOutcome] = []
        public var alreadyPresent: [SendOutcome] = []
        public var unconfirmed: [SendOutcome] = []
        public var failed: [SendOutcome] = []
    }

    private let library: LibraryService
    private let sends: SendRegistry
    private let devices: DeviceRegistry

    public init(library: LibraryService, sends: SendRegistry, devices: DeviceRegistry) {
        self.library = library; self.sends = sends; self.devices = devices
    }

    public func run(destination: any SendDestination, items: [SendItem], vault: Vault,
                    progress: (@Sendable (SendProgress) -> Void)? = nil) async -> Result {
        var result = Result()

        // 1. Remember the device (friendly name + last-seen).
        devices.upsert(key: destination.destinationKey, name: destination.displayName,
                       kind: destination.deviceKind.rawValue, at: ISO8601Millis.string(from: Date()))

        // 2. Live dedup against what's currently on the target.
        let present = (try? await destination.enumeratePresent()) ?? []
        var toSend: [SendItem] = []
        for item in items {
            if isPresent(item, in: present) {
                result.alreadyPresent.append(SendOutcome(item: item, status: .alreadyPresent))
            } else {
                toSend.append(item)
            }
        }

        // 3. Send the remainder.
        let outcomes: [SendOutcome]
        if toSend.isEmpty {
            outcomes = []
        } else {
            outcomes = (try? await destination.send(toSend, progress: { progress?($0) }))
                ?? toSend.map { SendOutcome(item: $0, status: .failed, error: "send failed") }
        }

        // 4. Record confirmed sends; bucket the rest.
        let now = ISO8601Millis.string(from: Date())
        for o in outcomes {
            switch o.status {
            case .confirmed:
                try? sends.append(.init(
                    hash: o.item.hash, destinationKey: destination.destinationKey,
                    deviceName: destination.displayName, deviceKind: destination.deviceKind.rawValue,
                    sentAt: now, confirmedAt: now,
                    fpSize: o.item.fingerprint.size, fpCaptureDateMs: o.item.fingerprint.captureDateMs))
                result.confirmed.append(o)
            case .unconfirmed: result.unconfirmed.append(o)
            case .failed: result.failed.append(o)
            case .alreadyPresent: result.alreadyPresent.append(o)
            }
        }

        // 5. Journal.
        library.appendSyncLog(vault: vault, event: "send",
            summary: "\(result.confirmed.count) sent, \(result.alreadyPresent.count) already there, " +
                     "\(result.unconfirmed.count) unconfirmed, \(result.failed.count) failed → \(destination.displayName)",
            counterpartyKey: destination.destinationKey)
        return result
    }

    /// Two-layer dedup: authoritative content hash when the target exposes it
    /// (volumes), else the size+capture-second fingerprint (phones).
    private func isPresent(_ item: SendItem, in present: [PresenceFingerprint]) -> Bool {
        present.contains { p in
            if let ph = p.hash { return ph == item.hash }
            return p.looselyMatches(item.fingerprint)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "sendEngine"` (3 pass), then `swift test` (full green — 90).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Send/SendEngine.swift Tests/OpenPhotoCoreTests/FakeSendDestination.swift Tests/OpenPhotoCoreTests/SendEngineTests.swift
git commit -m "$(cat <<'EOF'
feat: SendEngine — dedup, send, record confirmed sends

Remembers the device, skips assets already on the target (hash when the
target exposes it, else size+date fingerprint), sends the rest, records
only confirmed sends in sends.jsonl, and journals a send event.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: VolumeCopyDestination

**Files:**
- Create: `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift`
- Test: `Tests/OpenPhotoCoreTests/VolumeCopyDestinationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/VolumeCopyDestinationTests.swift` (uses `makeJPEG`/`creatingParent()` from the test target):

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

@Test func volumeCopyConfirmsByHashAndDedupsOnResend() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    // A "library" original and a fake "volume" root.
    let lib = try t.sub("lib")
    let srcURL = lib.appendingPathComponent("IMG_1.jpg")
    try makeJPEG(at: srcURL, dateTimeOriginal: "2015:06:15 14:30:00", lat: nil, lon: nil)
    let hash = try ContentHash.ofFile(at: srcURL).stringValue
    let size = Int64((try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int) ?? 0)
    let volRoot = try t.sub("VOLUME")

    let dest = VolumeCopyDestination(volumeRoot: volRoot, displayName: "Card")
    let send = SendItem(hash: hash, originalURL: srcURL,
                        fingerprint: PresenceFingerprint(size: size, captureDateMs: 0, hash: hash),
                        displayName: "IMG_1.jpg")
    // First send: copied + hash-verified → confirmed; file lands in OpenPhoto/ on the volume.
    let out1 = try await dest.send([send], progress: { _ in })
    #expect(out1.count == 1 && out1[0].status == .confirmed)
    let landed = volRoot.appendingPathComponent("OpenPhoto/IMG_1.jpg")
    #expect(FileManager.default.fileExists(atPath: landed.path))
    #expect(try ContentHash.ofFile(at: landed).stringValue == hash)   // byte-identical copy

    // enumeratePresent now reports it (with hash) → engine would dedup a re-send.
    let present = try await dest.enumeratePresent()
    #expect(present.contains { $0.hash == hash })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter volumeCopyConfirmsByHashAndDedupsOnResend`
Expected: FAIL — "cannot find 'VolumeCopyDestination' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift`:

```swift
import Foundation
import ImageIO
import CoreGraphics

/// Sends library assets to a mounted volume (SD card / USB) by direct copy into a
/// destination subfolder, verified byte-for-byte by content hash. Fully testable.
public final class VolumeCopyDestination: SendDestination, @unchecked Sendable {
    public let destinationKey: String
    public let displayName: String
    public let deviceKind: DeviceKind = .volume
    private let folderURL: URL

    public init(volumeRoot: URL, subfolder: String = "OpenPhoto", displayName: String) {
        let resolved = volumeRoot.resolvingSymlinksInPath()
        self.folderURL = resolved.appendingPathComponent(subfolder)
        self.displayName = displayName
        let uuid = (try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        self.destinationKey = "vol-" + (uuid ?? resolved.path.precomposedStringWithCanonicalMapping)
    }

    public func enumeratePresent() async throws -> [PresenceFingerprint] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [PresenceFingerprint] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, MediaKind.of(filename: url.lastPathComponent) != nil else { continue }
            let size = Int64(v?.fileSize ?? 0)
            let captureMs = Self.captureDateMs(of: url, mtime: v?.contentModificationDate)
            let hash = try? ContentHash.ofFile(at: url).stringValue
            out.append(PresenceFingerprint(size: size, captureDateMs: captureMs, hash: hash))
        }
        return out
    }

    public func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var outcomes: [SendOutcome] = []
        for (i, item) in items.enumerated() {
            progress(SendProgress(stage: .sending, done: i, total: items.count, currentName: item.displayName))
            let target = collisionFreeURL(for: item.displayName, in: folderURL)
            do {
                try fm.copyItem(at: item.originalURL, to: target)
                let writtenHash = try ContentHash.ofFile(at: target).stringValue
                if writtenHash == item.hash {
                    outcomes.append(SendOutcome(item: item, status: .confirmed))
                } else {
                    try? fm.removeItem(at: target)
                    outcomes.append(SendOutcome(item: item, status: .failed, error: "verify mismatch"))
                }
            } catch {
                outcomes.append(SendOutcome(item: item, status: .failed, error: String(describing: error)))
            }
        }
        return outcomes
    }

    // EXIF DateTimeOriginal for photos (cheap header read), else file mtime.
    private static func captureDateMs(of url: URL, mtime: Date?) -> Int64 {
        if MediaKind.of(filename: url.lastPathComponent) == .photo,
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        if let m = mtime { return Int64(m.timeIntervalSince1970 * 1000) }
        return 0
    }

    /// IMG_1.JPG → IMG_1 (2).JPG … (mirror of ImportEngine's collision-safe naming).
    private func collisionFreeURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(suffixed)
            n += 1
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter volumeCopyConfirmsByHashAndDedupsOnResend` (pass), then `swift test` (full green — 91).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift Tests/OpenPhotoCoreTests/VolumeCopyDestinationTests.swift
git commit -m "$(cat <<'EOF'
feat: VolumeCopyDestination — copy to an SD/volume, verified by hash

Copies originals into an OpenPhoto/ folder on the volume with collision-safe
names, re-hashes each written file and confirms only on a byte-for-byte
match; enumeratePresent exposes hashes so re-sends dedup authoritatively.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Format docs — §13 sends, §14 devices, §9 send event

**Files:**
- Modify: `docs/format/vault-format-v1.md`

- [ ] **Step 1: Add §13 and §14, and the send event in §9**

In `docs/format/vault-format-v1.md`, find §12 (import registry) and add the following two new sections AFTER it (so §13, §14 come after §12):

````markdown
## 13. Send registry (`sends.jsonl`)

Durable record of every asset OpenPhoto has **confirmed** sending to a device
(phone via AirDrop, or a mounted volume via copy). One JSON object per line:

```json
{"confirmed_at":"2026-06-08T13:31:12.000Z","destination_key":"vol-ABC123","device_kind":"volume","device_name":"Backup SSD","fp_capture_date_ms":1434378600000,"fp_size":31853,"hash":"sha256:…","sent_at":"2026-06-08T13:30:00.000Z"}
```

- `hash` — the library asset's content hash (`sha256:` …).
- `destination_key` — stable device identity (phone serial / volume UUID); same keyspace as `imports.jsonl`'s `source_key`.
- `device_kind` — `"phone"` | `"volume"`.
- `fp_size` / `fp_capture_date_ms` — the size + capture date (epoch ms) used as a cheap "is it still there?" fingerprint on re-connect. **Filename is deliberately not recorded** — Apple Photos rewrites it when a photo is saved.
- Lookup key is `(destination_key, hash)`; entries are append-only and never pruned. Only confirmed sends are recorded (an AirDrop with no verified landing writes nothing).
- Lives in the **primary** vault's `.openphoto/`.

## 14. Device registry (`devices.jsonl`)

Known devices OpenPhoto has seen, for friendly names in the UI. One JSON object per line:

```json
{"first_seen":"2026-06-08T10:00:00.000Z","key":"vol-ABC123","kind":"volume","last_seen":"2026-06-09T18:22:00.000Z","name":"Backup SSD"}
```

- `key` — stable device identity (same keyspace as above). `kind` — `"phone"` | `"volume"`.
- `name` and `last_seen` update on each connect; `first_seen` is preserved. Informative; readers MUST NOT require it.
- Lives in the **primary** vault's `.openphoto/`.
````

Then update **§9 `sync-log.jsonl`**: in the sentence listing event names, add `"send"`. The current line is:
```
Event names include `"import"`, `"device-delete"`, `"sync"`, `"clone"`, `"evict"`.
```
Change it to:
```
Event names include `"import"`, `"device-delete"`, `"send"`, `"sync"`, `"clone"`, `"evict"`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/format/vault-format-v1.md
git commit -m "$(cat <<'EOF'
docs(format): §13 sends.jsonl, §14 devices.jsonl, send sync-log event

Normative schemas for the send registry and known-device registry, per the
sovereignty documentation discipline (third-party readers implement against
these). fp_* fields are size+capture-date; filename omitted (Photos rewrites it).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: AppState send plumbing

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add registries, destination factory, and send helpers**

In `Sources/OpenPhotoApp/AppState.swift`, add lazily-created registries next to the existing `importRegistry` computed property:

```swift
    private var _sendRegistry: SendRegistry?
    var sendRegistry: SendRegistry? {
        if _sendRegistry == nil, let primary = library?.vaults.first {
            _sendRegistry = SendRegistry(vault: primary)
        }
        return _sendRegistry
    }
    private var _deviceRegistry: DeviceRegistry?
    var deviceRegistry: DeviceRegistry? {
        if _deviceRegistry == nil, let primary = library?.vaults.first {
            _deviceRegistry = DeviceRegistry(vault: primary)
        }
        return _deviceRegistry
    }
```

Then add these methods inside `final class AppState` (e.g. just after the `evict(_:)` method from Stage A):

```swift
    /// The connected device we can currently send to, if any. Stage B1: volumes only
    /// (the iPhone/AirDrop destination arrives in Stage B2).
    func connectedSendTarget() -> ConnectedDevice? {
        deviceWatcher.devices.first { if case .volume = $0 { true } else { false } }
    }

    /// Build a SendDestination for a connected device. Stage B1: volumes only.
    func sendDestination(for device: ConnectedDevice) -> (any SendDestination)? {
        switch device {
        case .volume(_, let name, let url): return VolumeCopyDestination(volumeRoot: url, displayName: name)
        case .camera: return nil   // Stage B2: AirDropDestination
        }
    }

    /// Map a library item to a SendItem (read-only original + fingerprint).
    func sendItem(for item: TimelineItem) -> SendItem? {
        guard let url = library?.absoluteURL(for: item) else { return nil }
        return SendItem(
            hash: item.hash, originalURL: url,
            fingerprint: PresenceFingerprint(size: item.size, captureDateMs: item.takenAtMs, hash: item.hash),
            displayName: (item.relPath as NSString).lastPathComponent)
    }

    /// Send a selection to a connected device, reporting progress. Returns the result.
    func send(_ items: [TimelineItem], to device: ConnectedDevice,
              progress: @escaping @Sendable (SendProgress) -> Void) async -> SendEngine.Result? {
        guard let library, let vault = library.vaults.first,
              let sends = sendRegistry, let devices = deviceRegistry,
              let destination = sendDestination(for: device) else { return nil }
        let sendItems = items.compactMap { sendItem(for: $0) }
        let engine = SendEngine(library: library, sends: sends, devices: devices)
        let result = await engine.run(destination: destination, items: sendItems, vault: vault, progress: progress)
        try? refreshQueries()
        return result
    }
```

- [ ] **Step 2: Build**

Run: `swift build` → zero warnings. (All Send types resolve via the existing `import OpenPhotoCore`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "$(cat <<'EOF'
feat: AppState send plumbing — registries, destination factory, send()

Lazy sends.jsonl/devices.jsonl registries, a SendDestination factory
(volumes in B1), TimelineItem→SendItem mapping, and a send() that runs
the SendEngine with progress and refreshes after.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: "Send to device" UI — action bar button + SendSheet

**Files:**
- Modify: `Sources/OpenPhotoApp/Selection/SelectionUI.swift` (extend `SelectionActionBar`)
- Create: `Sources/OpenPhotoApp/Send/SendSheet.swift`
- Modify: `Sources/OpenPhotoApp/Timeline/TimelineView.swift`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift`

- [ ] **Step 1: Extend `SelectionActionBar` with an optional Send button**

In `Sources/OpenPhotoApp/Selection/SelectionUI.swift`, replace the `SelectionActionBar` struct with:

```swift
/// The toolbar shown while a grid is in select mode.
struct SelectionActionBar: View {
    let count: Int
    var sendTargetName: String? = nil       // non-nil → show "Send to <name>"
    var onSend: () -> Void = {}
    let onEvict: () -> Void
    let onDeselect: () -> Void
    let onDone: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Deselect", action: onDeselect).disabled(count == 0).controlSize(.small)
            if let name = sendTargetName {
                Button(action: onSend) {
                    Label("Send to \(name)", systemImage: "paperplane")
                }.disabled(count == 0).controlSize(.small)
            }
            Button(role: .destructive, action: onEvict) {
                Label("Evict…", systemImage: "trash")
            }
            .disabled(count == 0).controlSize(.small)
            Button("Done", action: onDone).controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
```

(The new `sendTargetName`/`onSend` have defaults, so any call site that doesn't set them is unaffected.)

- [ ] **Step 2: Create the SendSheet**

Create `Sources/OpenPhotoApp/Send/SendSheet.swift`:

```swift
import SwiftUI
import OpenPhotoCore

/// Runs a send of `items` to `device` and shows progress + a result summary.
struct SendSheet: View {
    @Bindable var state: AppState
    let items: [TimelineItem]
    let device: ConnectedDevice
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress: SendProgress?
    @State private var result: SendEngine.Result?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send \(items.count) to \(device.name)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss(); onDone() }.disabled(running)
            }
            .padding(16)
            Divider().overlay(Theme.hairline)

            Group {
                if let result {
                    resultView(result)
                } else if let p = progress {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .tint(Theme.accent)
                        Text("\(p.stage == .verifying ? "Verifying" : "Copying")… \(p.done)/\(p.total) · \(p.currentName)")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                    }.padding(24)
                } else {
                    ProgressView().padding(24)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 520, height: 320)
        .task { await run() }
    }

    private func resultView(_ r: SendEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(r.confirmed.count) sent & verified to \(device.name)",
                  systemImage: "checkmark.seal").foregroundStyle(Theme.green)
            if !r.alreadyPresent.isEmpty {
                Text("\(r.alreadyPresent.count) already on \(device.name) — skipped")
                    .foregroundStyle(Theme.textDim)
            }
            if !r.unconfirmed.isEmpty {
                Text("\(r.unconfirmed.count) not confirmed")
                    .foregroundStyle(Theme.amber)
            }
            if !r.failed.isEmpty {
                Text("\(r.failed.count) failed").foregroundStyle(Theme.amber)
                ForEach(r.failed, id: \.item.hash) { o in
                    Text("• \(o.item.displayName): \(o.error ?? "")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.amber)
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    private func run() async {
        guard !running, result == nil else { return }
        running = true
        let r = await state.send(items, to: device) { p in
            Task { @MainActor in progress = p }
        }
        result = r ?? SendEngine.Result()
        running = false
    }
}
```

- [ ] **Step 3: Wire the SendSheet into the Timeline**

In `Sources/OpenPhotoApp/Timeline/TimelineView.swift`, add a `@State private var showSend = false` next to the other `@State`s, change `selectionBar` to pass the send target, and add the sheet.

Replace the `selectionBar` computed property with:

```swift
    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onEvict: { showEvict = true },
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false })
    }
```

And add this `.sheet` modifier on the `body`'s `VStack` (right after the existing `.alert(...)` block):

```swift
        .sheet(isPresented: $showSend) {
            if let target = state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) {
                    selection.clear(); selectMode = false
                }
            }
        }
```

- [ ] **Step 4: Wire the SendSheet into the Folder view**

In `Sources/OpenPhotoApp/Folders/FolderGridView.swift`, add `@State private var showSend = false`, replace `selectionBar` with:

```swift
    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            sendTargetName: state.connectedSendTarget()?.name,
            onSend: { showSend = true },
            onEvict: { showEvict = true },
            onDeselect: { selection.clear() },
            onDone: { selection.clear(); selectMode = false })
    }
```

and add the same `.sheet` after the existing `.alert(...)` block:

```swift
        .sheet(isPresented: $showSend) {
            if let target = state.connectedSendTarget() {
                SendSheet(state: state, items: selectedItems, device: target) {
                    selection.clear(); selectMode = false
                }
            }
        }
```

- [ ] **Step 5: Build**

Run: `swift build` → zero warnings.

- [ ] **Step 6: Smoke test**

Run: `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
With a removable SD/USB volume **mounted** (must have a top-level `DCIM` folder to be recognized — for testing you can create one): in Timeline → **Select** a few photos → the action bar shows **Send to <volume>** → tap it → the sheet copies + verifies → result says "N sent & verified". Check the volume's `OpenPhoto/` folder has byte-identical copies. Re-send the same photos → they report "already on <volume> — skipped". Repeat in Folders. If no volume is mounted, the Send button simply doesn't appear (Evict still works).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoApp/Selection/SelectionUI.swift Sources/OpenPhotoApp/Send/SendSheet.swift Sources/OpenPhotoApp/Timeline/TimelineView.swift Sources/OpenPhotoApp/Folders/FolderGridView.swift
git commit -m "$(cat <<'EOF'
feat: Send-to-device UI — action bar button + SendSheet (volumes)

SelectionActionBar gains an optional "Send to <device>"; SendSheet runs
the SendEngine with live progress and a result summary. Wired into the
timeline and folder select modes for mounted volumes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `swift build` — zero warnings.
- [ ] `swift test` — full suite green (was 84; now +~7 → ~91).
- [ ] App smoke: select photos → **Send to <volume>** → verified copies land in `OpenPhoto/` on the card → re-send is skipped as already-present → `sends.jsonl` and `devices.jsonl` exist in the primary vault's `.openphoto/`.

## Self-review (completed while writing)

- **Spec coverage (Stage B, volume half):** `SendDestination`+types → Task 1; `SendRegistry`/`sends.jsonl` → Task 2 + §13; `DeviceRegistry`/`devices.jsonl` → Task 3 + §14; `SendEngine` + two-layer dedup → Task 4; `VolumeCopyDestination` (the volume transport, copy+hash-verify) → Task 5; send event → Task 6; "Send to <device>" action + flow → Tasks 7–8. **Deferred to Stage B2:** `AirDropDestination` (NSSharingService + ICC poll-verify), reconcile-on-connect presence beyond live-dedup, and the import-grid "already on this device / sent from here" labels.
- **Type consistency:** `PresenceFingerprint(size:captureDateMs:hash:)` / `.looselyMatches`; `SendItem(hash:originalURL:fingerprint:displayName:)`; `SendOutcome(item:status:error:)` with `Status{confirmed,alreadyPresent,unconfirmed,failed}`; `SendDestination{destinationKey,displayName,deviceKind,enumeratePresent(),send(_:progress:)}`; `SendRegistry.Entry`/`.contains(destinationKey:hash:)`/`.entries(forDestinationKey:)`/`.append`; `DeviceRegistry.upsert(key:name:kind:at:)`/`.name(forKey:)`/`.entry(forKey:)`; `SendEngine(library:sends:devices:)`/`.run(destination:items:vault:progress:)->Result`; `VolumeCopyDestination(volumeRoot:subfolder:displayName:)`; `AppState.connectedSendTarget()`/`sendDestination(for:)`/`sendItem(for:)`/`send(_:to:progress:)`; `SelectionActionBar(count:sendTargetName:onSend:onEvict:onDeselect:onDone:)` — all consistent across tasks.
- **No placeholders:** every code step is complete; the modified `SelectionActionBar` and `selectionBar`/sheet wiring are shown in full.
- **Safety:** send is non-destructive (copy only; never deletes library or device). Volume copies are hash-verified before being recorded as confirmed; a mismatch removes the bad copy and reports failure.
