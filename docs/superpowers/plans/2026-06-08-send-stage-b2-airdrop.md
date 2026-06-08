# Send to iPhone via AirDrop + Provenance Labels (Stage B2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the iPhone transport — an `AirDropDestination` that sends library photos to a connected iPhone via AirDrop and confirms them by re-enumerating the device — slotting into the Stage B1 pipeline/UI, plus import-grid "sent from here" provenance labels.

**Architecture:** `AirDropDestination` (App layer — uses AppKit `NSSharingService` + the existing `CameraSource` for ICC enumeration) conforms to the Core `SendDestination` protocol. `send()` presents AirDrop, then polls `enumeratePresent()` (size+date fingerprint, proven byte-stable by the round-trip spike) until each item lands or a timeout. `AppState` wires it in as the destination for connected cameras. A new `SendRegistry.wasSentToDevice` powers a "Sent from here" badge in the import grid so a returned photo is never mistaken for a new import.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSSharingService`), ImageCaptureCore (via `CameraSource`), SwiftPM, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md` (Stage B, AirDrop half). **Builds on Stage B1** (`SendDestination`, `SendEngine`, `SendRegistry`, `SendSheet`, `AppState.send`). The AirDrop spikes already proved: AirDrop lands photos in the main library at their date, and library→AirDrop→Photos→reimport is byte-identical and matchable by size+date.

---

## Conventions for every task
- **Build:** `swift build` — zero warnings. **Test:** `swift test` (full) / `--filter <name>`. **Run:** `killall OpenPhoto 2>/dev/null; ./scripts/make-app.sh && open build/OpenPhoto.app`
- Never touch real user folders — generated fixtures only.
- TDD for the testable core (Task 1). The `AirDropDestination` (Task 2) and UI (Tasks 3–4) are implement → build (0 warnings) → commit; their hardware behavior is validated by a final on-device smoke test (the user runs it).
- Commit each task with the exact message given.

## File structure
**Modify (Core, tested):** `Sources/OpenPhotoCore/Send/SendRegistry.swift` — add `wasSentToDevice(destinationKey:size:captureDateMs:)`.
**Create (App):** `Sources/OpenPhotoApp/Send/AirDropDestination.swift` — the iPhone transport.
**Modify (App):** `Sources/OpenPhotoApp/AppState.swift` — `sendDestination(.camera)` + broaden `connectedSendTarget`. `Sources/OpenPhotoApp/Devices/ImportItemCell.swift` — "Sent from here" badge. `Sources/OpenPhotoApp/Devices/ImportView.swift` — compute + pass the sent flag.

---

## Task 1: SendRegistry.wasSentToDevice (fingerprint lookup for labels)

**Files:**
- Modify: `Sources/OpenPhotoCore/Send/SendRegistry.swift`
- Test: `Tests/OpenPhotoCoreTests/SendRegistryTests.swift`

- [ ] **Step 1: Write the failing test.** Append to `Tests/OpenPhotoCoreTests/SendRegistryTests.swift`:

```swift
@Test func wasSentToDeviceMatchesByFingerprint() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let vault = try Vault.openOrCreate(at: try t.sub("Pictures"), role: .local)
    let reg = SendRegistry(vault: vault)
    let h = "sha256:" + String(repeating: "a", count: 64)
    try reg.append(SendRegistry.Entry(hash: h, destinationKey: "cam-IPHONE",
        deviceName: "iPhone", deviceKind: "phone",
        sentAt: "2026-06-08T13:30:00.000Z", confirmedAt: "2026-06-08T13:31:00.000Z",
        fpSize: 31853, fpCaptureDateMs: 1_434_378_600_000))
    // Same device + size + capture second → match (sub-second drift ignored).
    #expect(reg.wasSentToDevice(destinationKey: "cam-IPHONE", size: 31853, captureDateMs: 1_434_378_600_400))
    #expect(!reg.wasSentToDevice(destinationKey: "cam-OTHER", size: 31853, captureDateMs: 1_434_378_600_000)) // other device
    #expect(!reg.wasSentToDevice(destinationKey: "cam-IPHONE", size: 99, captureDateMs: 1_434_378_600_000))   // other size
    #expect(!reg.wasSentToDevice(destinationKey: "cam-IPHONE", size: 31853, captureDateMs: 0))                // unknown date never matches
}
```

- [ ] **Step 2: Run test to verify it fails.** `swift test --filter wasSentToDeviceMatchesByFingerprint` → "has no member 'wasSentToDevice'".

- [ ] **Step 3: Add the method.** In `Sources/OpenPhotoCore/Send/SendRegistry.swift`, after `entries(forDestinationKey:)`, add:

```swift
    /// Has anything with this fingerprint been confirmed-sent to this device?
    /// Matches size + capture second (filenames aren't recorded — Photos rewrites
    /// them). An unknown (0) capture date never matches.
    public func wasSentToDevice(destinationKey: String, size: Int64, captureDateMs: Int64) -> Bool {
        guard captureDateMs != 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return byKey.values.contains { e in
            e.destinationKey == destinationKey && e.fpSize == size &&
            e.fpCaptureDateMs / 1000 == captureDateMs / 1000
        }
    }
```

- [ ] **Step 4: Run the test.** `swift test --filter wasSentToDeviceMatchesByFingerprint` (pass), then `swift test` (full green — 95).

- [ ] **Step 5: Commit.**
```bash
git add Sources/OpenPhotoCore/Send/SendRegistry.swift Tests/OpenPhotoCoreTests/SendRegistryTests.swift
git commit -m "$(cat <<'EOF'
feat: SendRegistry.wasSentToDevice — fingerprint lookup for import labels

Matches a device item (size + capture second) against confirmed sends to
that device, so a returned photo can be badged "sent from here". Unknown
dates never match.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: AirDropDestination (the iPhone transport)

**Files:**
- Create: `Sources/OpenPhotoApp/Send/AirDropDestination.swift`

(No unit test — depends on AppKit AirDrop + a physical device. Verified by `swift build` here and an on-device smoke test at the end.)

- [ ] **Step 1: Create the file.**

```swift
import AppKit
import OpenPhotoCore

/// Sends library photos to a connected iPhone via AirDrop, then confirms each by
/// re-enumerating the device over USB (size+date fingerprint — proven byte-stable
/// by the round-trip spike). The cable is used only for identity + verification;
/// AirDrop is the transport. Thin + hardware-validated (not unit-tested).
final class AirDropDestination: SendDestination, @unchecked Sendable {
    let destinationKey: String
    let displayName: String
    let deviceKind: DeviceKind = .phone
    private let camera: CameraSource

    init(camera: CameraSource) {
        self.camera = camera
        self.destinationKey = camera.sourceKey      // same keyspace as imports (cam-<serial>)
        self.displayName = camera.displayName
    }

    /// Current contents of the iPhone as size+date fingerprints (no hash — can't
    /// cheaply hash device files). Opens the session if needed.
    func enumeratePresent() async throws -> [PresenceFingerprint] {
        try await camera.open()
        let items = try await camera.enumerateItems()
        return items.map {
            PresenceFingerprint(
                size: $0.byteSize,
                captureDateMs: $0.takenAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
                hash: nil)
        }
    }

    /// Present the macOS AirDrop sheet for the originals, then poll the device
    /// until each item's fingerprint appears (confirmed) or a timeout (unconfirmed).
    func send(_ items: [SendItem], progress: @Sendable (SendProgress) -> Void) async throws -> [SendOutcome] {
        let urls = items.map(\.originalURL)
        await MainActor.run {
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        }
        progress(SendProgress(stage: .verifying, done: 0, total: items.count, currentName: ""))

        var confirmed = Set<Int>()
        // Poll up to ~90s. Each enumerate itself takes a few seconds (ICC settle),
        // so the effective interval is enumerate-time + the sleep below.
        for _ in 0..<30 {
            if confirmed.count == items.count { break }
            try? await Task.sleep(for: .seconds(2))
            let present = (try? await enumeratePresent()) ?? []
            for (i, item) in items.enumerated() where !confirmed.contains(i) {
                if present.contains(where: { $0.looselyMatches(item.fingerprint) }) {
                    confirmed.insert(i)
                }
            }
            progress(SendProgress(stage: .verifying, done: confirmed.count,
                                  total: items.count, currentName: ""))
        }
        return items.enumerated().map { i, item in
            SendOutcome(item: item, status: confirmed.contains(i) ? .confirmed : .unconfirmed)
        }
    }
}
```

- [ ] **Step 2: Build.** `swift build` → confirm **zero warnings**. If `NSSharingService(named:)` or `.sendViaAirDrop` emits a deprecation warning on this SDK, resolve it minimally (e.g. keep the call but silence via the documented non-deprecated path) and report what you changed — do NOT change the verification logic.

- [ ] **Step 3: Commit.**
```bash
git add Sources/OpenPhotoApp/Send/AirDropDestination.swift
git commit -m "$(cat <<'EOF'
feat: AirDropDestination — send to iPhone via AirDrop + verify by re-enumeration

Presents the macOS AirDrop sheet for the originals, then polls the device
(ICC) until each photo's size+date fingerprint appears, marking it confirmed
(else unconfirmed on timeout). Cable = identity + verify; AirDrop = transport.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire AirDropDestination into AppState

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Make cameras send-capable.** In `Sources/OpenPhotoApp/AppState.swift`, replace the existing `connectedSendTarget()` and `sendDestination(for:)` (added in B1) with:

```swift
    /// The connected device we can currently send to, if any. Cameras (AirDrop)
    /// are listed first by DeviceWatcher, so a connected iPhone is preferred.
    func connectedSendTarget() -> ConnectedDevice? {
        deviceWatcher.devices.first { sendDestination(for: $0) != nil }
    }

    /// Build a SendDestination for a connected device: AirDrop for an iPhone,
    /// direct copy for a volume.
    func sendDestination(for device: ConnectedDevice) -> (any SendDestination)? {
        switch device {
        case .volume(_, let name, let url):
            return VolumeCopyDestination(volumeRoot: url, displayName: name)
        case .camera:
            guard let cam = deviceWatcher.source(for: device) as? CameraSource else { return nil }
            return AirDropDestination(camera: cam)
        }
    }
```

- [ ] **Step 2: Build.** `swift build` → zero warnings.

- [ ] **Step 3: Commit.**
```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "$(cat <<'EOF'
feat: AppState routes connected iPhones to AirDropDestination

connectedSendTarget now offers any send-capable device (iPhone preferred);
sendDestination builds an AirDropDestination for cameras, VolumeCopyDestination
for volumes. The Send-to-device UI from B1 now works for the iPhone.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: "Sent from here" label in the import grid

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/ImportItemCell.swift` (add a badge)
- Modify: `Sources/OpenPhotoApp/Devices/ImportView.swift` (compute + pass the flag)

- [ ] **Step 1: Add the badge to `ImportTile`/`ImportItemCell`.** In `Sources/OpenPhotoApp/Devices/ImportItemCell.swift`:

(a) Add a `sentFromHere` parameter to `ImportTile` (with a default so other callers — FreeUpPhoneView — are unaffected). Change the `ImportTile` property list and the `ImportItemCell(...)` call inside it:

In `struct ImportTile`, add after `let importedThisSession: Bool`:
```swift
    var sentFromHere: Bool = false
```
and in its body, update the `ImportItemCell(...)` initializer call to pass it:
```swift
                ImportItemCell(item: item, source: source,
                               alreadyImported: alreadyImported,
                               importedThisSession: importedThisSession,
                               sentFromHere: sentFromHere,
                               selected: selected)
```

(b) In `struct ImportItemCell`, add after `let importedThisSession: Bool`:
```swift
    var sentFromHere: Bool = false
```
and replace the `statusBadge` view builder with one that shows "Sent from here" when applicable (it takes priority over "already in library" since it's more specific provenance):
```swift
    @ViewBuilder private var statusBadge: some View {
        if importedThisSession {
            badge("Imported ✓", color: Theme.green)
        } else if sentFromHere {
            badge("Sent from here", color: Theme.blue)
        } else if alreadyImported {
            badge("Already in library", color: Theme.textFaint)
        }
    }
```

- [ ] **Step 2: Compute + pass the flag in `ImportView`.** In `Sources/OpenPhotoApp/Devices/ImportView.swift`:

(a) Add a state cache next to `importedIDCache`:
```swift
    @State private var sentIDCache = Set<String>()
```

(b) In the grid's `ImportTile(...)` call (in the `.ready, .importing` branch), add the `sentFromHere` argument:
```swift
                        ImportTile(
                            item: item, source: source!,
                            alreadyImported: isImported(item),
                            importedThisSession: sessionImportedIDs.contains(item.id),
                            sentFromHere: sentIDCache.contains(item.id),
                            selected: selection.contains(item.id),
                            onToggle: {
                                selection.tap(index: index, items: orderedSelectable,
                                              extendingRange: NSEvent.modifierFlags.contains(.shift))
                            })
                            .cellFrame(item.id, in: "importgrid")
```

(c) Add a helper that rebuilds `sentIDCache` from the SendRegistry, and call it wherever `rebuildImportedCache()` is called. Add this method next to `rebuildImportedCache()`:
```swift
    /// Mark items that OpenPhoto previously sent to THIS device (so a returned
    /// photo reads "sent from here", not a new import). Matched by fingerprint.
    private func rebuildSentCache() {
        guard let source, let reg = state.sendRegistry else { sentIDCache = []; return }
        var cache = Set<String>()
        for item in items {
            let ms = item.takenAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            if reg.wasSentToDevice(destinationKey: source.sourceKey,
                                   size: item.byteSize, captureDateMs: ms) {
                cache.insert(item.id)
            }
        }
        sentIDCache = cache
    }
```
Then call `rebuildSentCache()` immediately after each existing `rebuildImportedCache()` call (there are two: at the end of `reloadItems()` and at the end of `runBatch()`).

- [ ] **Step 3: Build.** `swift build` → zero warnings.

- [ ] **Step 4: Commit.**
```bash
git add Sources/OpenPhotoApp/Devices/ImportItemCell.swift Sources/OpenPhotoApp/Devices/ImportView.swift
git commit -m "$(cat <<'EOF'
feat: import grid badges photos OpenPhoto sent to this device

A device photo matching a confirmed send to that device shows "Sent from
here" (blue), so a round-tripped photo is recognized as ours rather than a
new import. Matched by the send registry's size+date fingerprint.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification
- [ ] `swift build` — zero warnings. `swift test` — full suite green (was 94; now +1 → 95).
- [ ] **On-device smoke (user, at the end):** plug in + unlock iPhone → Timeline → Select photos → action bar shows **Send to \<iPhone\>** → AirDrop sheet appears → pick the phone, accept, Save → the SendSheet ticks confirmations as photos land → confirmed photos appear in Apple Photos at their original date. Re-opening the import grid badges those photos **"Sent from here"**.

## Self-review (completed while writing)
- **Spec coverage (Stage B, AirDrop half):** AirDrop transport + verify → Task 2; routing → Task 3; import-grid "sent from here" provenance label → Tasks 1+4. (The "already on this phone" dedup at send time already works via B1's `SendEngine` live-enumeration through `AirDropDestination.enumeratePresent`.)
- **Type consistency:** `AirDropDestination(camera:)` conforms to `SendDestination` (destinationKey/displayName/deviceKind/enumeratePresent/send); reuses `CameraSource.sourceKey`/`.displayName`/`.open()`/`.enumerateItems()` and `ImportItem.byteSize`/`.takenAt`; `SendRegistry.wasSentToDevice(destinationKey:size:captureDateMs:)`; `ImportTile`/`ImportItemCell` gain `sentFromHere: Bool = false`. Consistent.
- **No placeholders:** every step has complete code.
- **Risk:** `NSSharingService` AirDrop invocation + ICC re-enumeration verify are the only unverified pieces; they are isolated in `AirDropDestination` and validated by the on-device smoke. The verify mechanism itself (size+date match on re-enumeration) was already proven by the round-trip spike.
