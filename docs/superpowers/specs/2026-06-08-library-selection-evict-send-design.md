# OpenPhoto — Library Selection, Evict & Send-to-Device Design Spec

**Date:** 2026-06-08
**Status:** Approved by Jude (brainstorming session)
**Builds on:** [Phase 1 architecture spec](2026-06-07-openphoto-design.md) · [Phase 2 import spec](2026-06-08-phase2-import-design.md) · [vault format v1](../../format/vault-format-v1.md) (§8 bin, §9 sync-log, §12 imports) · [AirDrop restore spike](../../spikes/2026-06-08-airdrop-restore.md)

---

## 1. Scope

A **library selection system** with two bulk actions, plus the tracking that makes them safe and intelligent.

1. **Select mode** in the timeline and folder views — a *Select* button that turns on the same selection UX as the import screen (click-toggle, shift-click ranges, drag/rubber-band).
2. **Evict** the selection from this Mac — move to the recoverable bin, guarded by an *only-copy warning*.
3. **Send** the selection to any plugged-in device — an iPhone (via AirDrop, verified by re-enumeration) or a camera/SD volume (via direct copy, verified by hash).
4. **Tracking**: a durable `sends.jsonl` registry, a `devices.jsonl` known-devices registry, presence reconciliation when a device connects, and a **Locations** view in the metadata inspector ("where is this photo stored").

**Hard constraint — sending back to an iPhone over USB is impossible.** ImageCaptureCore/PTP is read+delete only for iOS (Apple's own Image Capture.app has no upload). AirDrop is therefore the iPhone transport; the USB cable is used *only* for device identity and verification, never for the transfer. (Documented in the AirDrop spike.)

**Out of scope (named so they don't creep):**
- Drive sync to canonical external drives — Phase 3. The Locations model is built *forward-compatible* with it, but pre-Phase-3 the only known locations are This Mac + phones/volumes we've sent to or imported from.
- A companion iOS app (the higher-fidelity alternative transport — would set exact dates, rebuild Live Photos, confirm-back). Recorded as a future option; not built now.
- Making photos appear on a *specific camera's* playback (DCF/DCIM naming conventions). Volume send copies files onto the card; whether a given camera indexes them is the camera's concern.
- Restoring Live Photo **motion** (the per-still `.mov` isn't available over USB anyway — see Phase 2 spike). Live Photos send/restore as the still only.

## 2. Decisions log

| Decision | Choice |
|---|---|
| iPhone transport | **AirDrop** of the original files (USB push is impossible). Cable = identity + verification only. |
| Volume/SD transport | **Direct file copy** onto the volume + byte/hash verify. Authoritative confirmation inline. |
| Identity model | **Plug-in bound.** Device identified by its stable key (phone serial / volume UUID) — same keyspace as `ImportSource.sourceKey`. Sends only happen while the target is connected. |
| Send verification | **Poll** the device after the AirDrop sheet opens; tick off each photo as it appears (match by size + capture-date); manual "check now / done" fallback. Volume copies verify inline by hash. |
| Send tracking | Durable **`sends.jsonl`** (vault-format §13), mirror of `imports.jsonl`. **Confirmed sends only** are logged. |
| Presence / staleness | Presence has **confidence + recency**: *confirmed* (seen on last connect), *believed* (sent/imported, not re-checked), *historical* (e.g. an SD card that's likely been reused). The Locations panel shows all three with dates; the only-copy judgment counts only confirmed/believed copies. |
| Dedup | **Two layers.** Layer 1 = content hash (round-trip stable per spike) — authoritative. Layer 2 = size+date fingerprint via the send log — a cheap pre-download label so sent photos never *appear* new in the import grid. **Filename is never an identity key** (Photos rewrites it). |
| Evict semantics | **Bin + only-copy warning.** Everything evicted goes to the recoverable §8 bin; if Presence finds no copy anywhere but this Mac, the app warns prominently first. You can still proceed. |
| Safety invariant | A hash/fingerprint match may only **suppress** an action (skip a copy/send), never **authorize a destructive** one. Any *permanent* delete (phone free-up) is gated by a full byte comparison. The bin makes every Mac-side eviction recoverable. |
| Selection logic | Extracted from the import screen into a **shared** component used by import, timeline, and folder views. |

## 3. Hardware evidence (already gathered)

Two spikes de-risked the load-bearing assumptions (full results in [the AirDrop spike doc](../../spikes/2026-06-08-airdrop-restore.md)):

- **Placement:** an AirDropped photo lands in the **main Photos library at its original EXIF date** (not a separate read-only "synced" album), shows native device/GPS attribution, and is a first-class editable asset. Files lacking an embedded capture date fall to "today".
- **Round-trip identity:** library → AirDrop → Apple Photos → re-import over USB returns the file **byte-for-byte identical** (verified by SHA-256, both a JPEG-with-EXIF and a metadata-less PNG). So Layer-1 hash dedup recognizes a sent-then-reimported photo automatically. **Apple Photos rewrites the filename** (random 8-char name) → filename is unusable as an identity key; size+capture-date is the fingerprint.

## 4. Core components

All headless logic lives in `OpenPhotoCore`; SwiftUI in `OpenPhotoApp`.

### 4.1 Shared selection (`OpenPhotoApp`)
Extract the import grid's selection behavior (`ImportView`/`ImportItemCell`) into a reusable `SelectionController` + grid modifier: click-toggle, shift-click range (via `NSEvent.modifierFlags`), and rubber-band drag-select (the existing `CellFramesKey` preference + `DragGesture` in a named coordinate space). A *Select* toolbar button toggles select mode in `TimelineView` and `FolderGridView`; a contextual **action bar** appears while items are selected (Evict · Send to <device> · Deselect). `ImportView` is refactored to consume the same controller — one selection implementation, three screens.

### 4.2 Evict (reuses existing bin)
Eviction = the existing §8 deletion via `BinStore`: move file (and its sidecar, and any Live-pair partner — pairs evict atomically) into `<vault-root>/.openphoto/bin/`, remove the manifest line, append to `bin.jsonl` with `origin:"user"`, update the catalog, append an `evict` event to `sync-log.jsonl`. Fully recoverable from the existing `BinView`. **No new deletion mechanism is introduced** — only the multi-select entry point and the only-copy warning (§6.2) are new. Each evicted photo's vault owns its bin (a selection spanning vaults bins into each).

### 4.3 `SendDestination` protocol (`OpenPhotoCore`)
The write-side mirror of `ImportSource`:
```
destinationKey: String                       // stable per target: phone serial / volume UUID (same keyspace as sourceKey)
displayName: String
deviceKind: .phone | .volume
// Push originals; verify before confirming. Returns one outcome per item.
send(_ items: [SendItem], progress: (SendProgress)->Void) async throws -> [SendOutcome]
// Current contents of the target — for verification + reconcile-on-connect.
enumeratePresent() async throws -> [PresenceFingerprint]
```
- `SendItem` = `{ hash, originalURL, fingerprint: (size, captureDate) }`. Originals are read-only (invariant #1).
- `PresenceFingerprint` = `{ size, captureDate, hash? }` — hash present only when cheap (volumes); phones use size+date.
- `SendOutcome` = `{ item, confirmed: Bool, fingerprint, error? }`.

**`AirDropDestination` (phone, ImageCaptureCore for identity/verify):** `send` hands the original file URLs to `NSSharingService(named: .sendViaAirDrop)`, then **polls** `enumeratePresent()` (ICC) until each item's size+date fingerprint appears, ticking progress, up to a timeout; unmatched items return `confirmed:false`. Stays thin; hardware-validated by checklist, not unit tests.

**`VolumeCopyDestination` (SD/folder, filesystem):** `send` copies each original onto the volume (atomic temp→rename) into a destination folder, **re-hashes the written file and compares to the source hash** (Layer-1 verify), returns `confirmed:true` only on exact match. Fully testable with fixtures.

### 4.4 `SendEngine` (`OpenPhotoCore`)
Orchestrates one send batch (selection + a connected `SendDestination`):
1. Resolve selection → `SendItem`s (read originals, compute/lookup hash + fingerprint). Expand Live pairs to the still only.
2. **Reconcile first** (§4.6) so already-present items are skipped (Layer-1/Layer-2 dedup) — never re-sent.
3. `destination.send(...)`, surfacing progress.
4. For each `confirmed` outcome: append a `sends.jsonl` entry; update catalog presence to *confirmed*; refresh `devices.jsonl` last-seen.
5. Append a `send` event to `sync-log.jsonl`. Return a `SendResult` (sent / skipped-already-present / unconfirmed / failed).

### 4.5 `SendRegistry` → `sends.jsonl` (vault-format §13)
Mirror of `ImportRegistry`. Lives in the **primary** vault's `.openphoto/`. One line per **confirmed** send; append-only, atomic rewrite (`AtomicFile`), never pruned (durable memory). See §10 for schema.

### 4.6 `DeviceRegistry` → `devices.jsonl` (vault-format §14) + Reconciler
`devices.jsonl` maps a stable `destination_key` → `{name, kind, first_seen, last_seen}` so the UI can show "Jude's iPhone" / "Backup SSD". Updated whenever a device connects (via the existing `DeviceWatcher`).

The **Reconciler** runs on connect: `enumeratePresent()` → match each known send/import for that device by fingerprint (volumes: by hash, authoritative; phones: by size+date) → update **catalog presence** (`confirmed` + last_seen if still there; flip to `absent` if a previously-confirmed item is gone — e.g. deleted on the phone). This is what keeps the send log honest: a photo you delete on the phone is detected next connect, before any send decision, so dedup never wrongly blocks a re-send.

### 4.7 `PresenceService` (catalog-derived, rebuildable)
Computes, for a content hash, the list of locations with status + recency. Sources: catalog membership (**This Mac** — which vault/folder), `imports.jsonl` (came-from), `sends.jsonl` (sent-to), live reconciliation, and (Phase 3) drive catalogs. Stored as a **catalog table** (machine-derived → rebuildable per invariant #2; *not* a sidecar, *not* normative format). Feeds the Locations panel (§6.4) and the only-copy judgment (§6.2). Forward-compatible: Phase-3 drives appear automatically once that catalog exists.

## 5. Safety / data-loss prevention

The one unacceptable outcome is losing a photo. SHA-256 accidental collision is ~1-in-10⁶⁵ for a million-photo library — far less likely than a bug in our own code — so we defend the *pattern*, not just the hash, with three rules:

1. **A match never authorizes destruction.** A hash or fingerprint match may only *suppress* an action (skip a copy, skip a send). It may never be the reason a file is destroyed.
2. **Permanent deletes are byte-verified.** The only irreversible action in the app is phone **free-up** delete (bypasses Recently Deleted — Phase 2 spike). Before any such delete, the on-device file is byte-compared against the retained library copy; mismatch → keep + flag. (This spec audits the existing free-up path to guarantee this; it is *not* part of evict or send.)
3. **Mac-side eviction is always recoverable.** Evict moves to the §8 bin, so even a wrong "it's safe" judgment cannot lose a photo. This is what makes the only-copy *warning* (not a hard block) the right design.

Send is **safe by construction**: it deletes nothing — not the library (read-only push), not the phone. Its worst failure is a photo *not sent* (wrongly judged already-present); the library copy is untouched and the user can force-send.

## 6. UI

### 6.1 Select mode
*Select* button in the timeline and folder toolbars → checkboxes + the shared selection UX (§4.1). The action bar shows **Evict** and **Send to <connected device name>** (the latter enabled only when a compatible device is connected; disabled with a hint otherwise).

### 6.2 Evict + only-copy warning
Evict → confirmation. If `PresenceService` finds **no confirmed/believed copy anywhere but this Mac**, the dialog elevates: *"N of these appear to exist only on this Mac. They'll go to the bin (recoverable) but aren't backed up anywhere OpenPhoto knows about."* Otherwise a plain "Move N to bin (recoverable)". Proceed → §4.2.

### 6.3 Send flow
Select → **Send to <device>**. Engine reconciles, shows "K already on <device> — skipping", then:
- **iPhone:** opens the AirDrop sheet (pick the phone, accept, Save). A progress panel polls and ticks each photo as it lands ("12 of 20 confirmed on Jude's iPhone"), with *Check now* / *Done*. Honest copy about Live-Photos-as-still and date-needs-EXIF.
- **Volume:** copies into a folder you pick on the card (default: a top-level `OpenPhoto/` folder) + verifies inline with a progress bar; confirmation is immediate.

### 6.4 Locations (metadata inspector)
`InspectorView` gains a **Locations** section for the selected/viewed photo: **This Mac** (vault · folder), then each device/drive with an icon, friendly name, and a status badge — *Confirmed* · *Last seen <date>* · *Historical*. This is the surfaced form of all the tracking above and the rationale behind the eviction warning.

## 7. Identity & dedup (two-layer)
- **Layer 1 — content hash (authoritative):** round-trip stable (spike). Drives the real "already have / already there" decisions and inline volume-copy verification.
- **Layer 2 — size+date fingerprint (advisory):** cheap, pre-download. Labels the import grid ("already on this phone / already in your library — sent from here") and matches AirDrop verification + reconciliation where hashing would require a download. Never authorizes anything destructive (§5).

## 8. Failure handling

| Failure | Behavior |
|---|---|
| Device unplugged mid-send | In-flight outcomes returned `unconfirmed`; nothing logged unless verified; library untouched |
| AirDrop declined / cancelled | Items stay `unconfirmed`; not logged; re-offer on next send |
| Verify timeout (photo not seen) | `unconfirmed`; user can *Check now* again or retry the send; library untouched |
| Volume copy hash mismatch | Item failed; written file removed; not logged; reported per item |
| Same size+date for two sent items | Verify match is ambiguous → both left `unconfirmed` (no false "confirmed"); optional deep-verify (download+hash) offered; nothing destructive happens |
| Evict of only copy | Allowed after explicit warning; recoverable from bin regardless |
| Photo deleted on phone since last send | Detected by reconcile-on-connect → presence flips to absent → eligible to re-send |

## 9. Testing
- `SendEngine`, `SendRegistry`, `DeviceRegistry`, `Reconciler`, `PresenceService`, two-layer dedup, only-copy judgment: full TDD with a `FakeSendDestination` (scriptable presence, confirm/timeout/mismatch). Generated fixtures only — never real user folders.
- `VolumeCopyDestination`: generated-fixture volumes (copy + verify + reconcile).
- `AirDropDestination`: thin; manual hardware checklist with Jude's iPhone (send happy path, decline, timeout, delete-on-phone-then-reconcile), like Phase 1/2.
- Evict: reuses `BinStore` tests; add multi-select + only-copy-warning coverage.
- Selection controller: unit-tested for range/drag/toggle logic; shared across the three screens.

## 10. Format-doc changes (same commit as the implementing code)

Per the documentation discipline, `docs/format/vault-format-v1.md` gains:

- **New §13 — `sends.jsonl`** (confirmed sends to devices), schema:
  ```json
  {"hash":"sha256:…","destination_key":"jude-iphone-ABC123","device_name":"jude’s iPhone","device_kind":"phone","sent_at":"2026-06-08T13:30:00.000Z","confirmed_at":"2026-06-08T13:31:12.000Z","fp_size":31853,"fp_taken_at":"2015-06-15T13:30:00.000Z"}
  ```
  Notes: confirmed sends only; never pruned; lives in the primary vault's `.openphoto/`; `fp_*` is the phone-side fingerprint observed at verify (filename deliberately omitted — Photos rewrites it).
- **New §14 — `devices.jsonl`** (known devices): `{key, name, kind, first_seen, last_seen}`; friendly-name source for the UI; informative.
- **§9 `sync-log.jsonl`:** add a `send` event example (`evict` already enumerated).
- Note that presence/Locations is a **catalog-derived view** (rebuildable, non-normative) — explicitly *not* a sidecar and *not* part of the on-disk contract.

## 11. Implementation staging (one spec, three shippable plans)

- **Stage A — Selection + Evict:** shared `SelectionController`; *Select* in timeline + folder; evict-to-bin via `BinStore`; only-copy warning using catalog + `imports.jsonl` presence. Independently shippable.
- **Stage B — Send to device:** `SendDestination` (+ AirDrop & Volume impls), `SendEngine`, `sends.jsonl`, `devices.jsonl`, Reconciler, two-layer dedup, import-grid labels. Builds on A.
- **Stage C — Locations:** `PresenceService` + the inspector Locations panel; upgrade the eviction warning to full presence. Builds on B.

Each stage gets its own implementation plan and produces working, tested software on its own.
