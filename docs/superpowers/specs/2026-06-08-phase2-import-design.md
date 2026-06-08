# OpenPhoto Phase 2 — Device Import Design Spec

**Date:** 2026-06-08
**Status:** Approved by Jude (brainstorming session)
**Builds on:** [Phase 1 architecture spec](2026-06-07-openphoto-design.md) §5.1 · [vault format v1](../../format/vault-format-v1.md) · [ICC spike findings](../../spikes/2026-06-08-icc-deletion.md) · import screen in `UI-Design/design_handoff_openphoto/import.jsx`

## 1. Scope

Import photos and videos from iPhones (USB, ImageCaptureCore) and mounted volumes (camera SD cards, any folder) into the library — slow and purposeful, with verified-copy-before-delete safety. Includes the durable import registry and the optional free-up-the-phone deletion flow.

**Out of scope (named so they don't creep):** drive sync (Phase 3), perceptual near-duplicates (Phase 5), auto-import rules, reading the phone's album structure (camera roll is taken flat).

## 2. Decisions log

| Decision | Choice |
|---|---|
| Architecture | Source-agnostic `ImportEngine` in OpenPhotoCore + pluggable `ImportSource` implementations (camera via ICC, volume via filesystem); engine fully testable with a `FakeSource` |
| Destination model | **Sequential batches**: one destination per import run; grid stays open between runs; multi-folder hauls via repetition |
| Already-imported detection | **Durable import registry** — `imports.jsonl` in the primary vault's `.openphoto/`, keyed by `(source_key, name, size, taken_at)`, recording content hash |
| Phone deletion | Session-end, opt-in, **selection screen with nothing preselected**; quick-select chips (This session · Screenshots · All · None); collapsed section for previously-imported items still on device; explicit permanence warning (spike: bypasses Recently Deleted) |
| Deletable set | Structurally limited to registry-verified items — never anything unverified |
| SD-card deletion | Move to `.openphoto-trash/` on the card — never unlink, even on removable media |
| Spike findings honored | Lock-wait-retry on error −9943; sort by capture date (device order is arbitrary); download→hash-verify→delete ritual |

## 3. Core components (all headless)

### `ImportSource` protocol
```
sourceKey: String                                   // stable per device: name+serial / volume UUID
enumerateItems() async throws -> [ImportItem]       // id, name, byteSize, takenAt, kind, livePairHint
fetch(_ item, to: URL) async throws                 // bytes → local staging file
delete(_ items: [ImportItem]) async throws -> [ItemResult]
state: AsyncStream<SourceState>                     // connected / waitingForUnlock / ready / gone
```

### `CameraSource` (ImageCaptureCore)
The spike's proven skeleton productionized: session open with locked device (−9943) → `waitingForUnlock` state, auto-retry on `cameraDeviceDidRemoveAccessRestriction`; enumeration sorted by capture date; per-item download via `requestDownloadFile`; per-item deletion via `requestDeleteFiles` with per-item results. Stays thin — hardware-validated by manual checklist, not unit tests.

### `VolumeSource` (SD cards, folders)
Walks media files (reusing `MediaKind`); fetch = file copy; delete = move into `.openphoto-trash/` at the volume root (never unlink). Fully testable with generated fixtures.

### `ImportRegistry`
`imports.jsonl` in the **primary vault's** `.openphoto/` — where *primary* = the first configured vault root (by convention `~/Pictures`; the registry stays there even when a batch's destination folder lives in another vault). One JSON line per imported item:
```json
{"source_key":"jude-iphone-ABC123","name":"IMG_6385.HEIC","size":2888127,"taken_at":"2026-06-08T01:15:58.000Z","hash":"sha256:…","imported_at":"2026-06-08T02:10:00.000Z","imported_to":"rome2026/IMG_6385.HEIC"}
```
O(1) lookup by `(source_key, name, size, taken_at)`. Atomic rewrite via `AtomicFile`. Survives library renames, evictions, and even deletion of the photo from the library ("imported once" is permanent memory). **Format doc gains §12 documenting this file**; `.openphoto/staging/` documented as transient (readers MUST ignore); the SD `.openphoto-trash/` convention documented alongside.

### `ImportEngine`
Runs one **batch** (source + selected items + destination folder in a vault):

1. Fetch item to `.openphoto/staging/<uuid>/` (staging is inside `.openphoto/` → never scanned, crash-safe)
2. Hash (streaming SHA-256)
3. Dedup check: hash already in catalog, or item already in registry → skip, count as duplicate, record registry entry if missing
4. Move into destination folder with collision-safe naming (`IMG_001 (2).heic`)
5. Incremental manifest + catalog update
6. **Verify**: re-hash the placed file; mismatch = failed item (placed file binned, not registry-recorded)
7. Append registry entry; emit per-item progress

Returns `BatchResult` (imported / skipped-duplicate / failed, per item). **Live Photo pairs are atomic**: selecting either half selects both; both halves fetch and place together; pairing itself is established by the existing scanner pass after the batch. Destination disk space pre-checked against the batch's total size before any copy. Batch events appended to `sync-log.jsonl` (`import` event).

### `DeviceWatcher` (app layer)
`ICDeviceBrowser` + volume-mount notifications populate the sidebar's contextual **Devices** section.

## 4. The import session (UI)

Plug in → Devices section shows the device → click → import screen:

- **Locked phone**: full-screen "Unlock your iPhone…" state (auto-proceeds on unlock)
- **Grid**: big thumbnails sorted newest-first; already-imported items badged + de-emphasized (registry lookup); Live pairs render as one tile with the LIVE badge; selection checkboxes per the mockup
- **Footer (select phase)**: "N of M selected · K already imported" + destination picker (recent destinations first, then folder tree, then "New folder…") + **Import N items**
- **Footer (importing)**: progress bar, "Copying & verifying… checksum verified before any deletion"
- **Batch done**: imported items gain ✓ badges; grid stays open; select more → new destination → repeat (sequential batches). The session accumulates verified items across batches; registry writes are per-item, so closing mid-session loses nothing.

## 5. Free-up-the-phone flow

When the session has verified items (or the registry knows of previously-imported items still on the device): a quiet **"Free up space on iPhone…"** footer button — never the default action. It opens a selection screen:

- Sections: **This session** + collapsed **Previously imported, still on phone**
- **Nothing preselected**; quick-select chips: *This session · Screenshots (PNG) · All · None*
- Only registry-verified items are listed — unverified items are structurally undeletable
- Confirmation names the stakes: *"Delete N photos from iPhone — immediate and permanent on the phone (no Recently Deleted). Verified copies exist in your library."*
- Per-item deletion with per-item failure reporting; no silent retries; results appended to `sync-log.jsonl` (`device-delete` event)

## 6. Failure handling

| Failure | Behavior |
|---|---|
| Unplug / lock mid-batch | In-flight staging discarded at next session start; verified items keep; remainder reported "not imported" |
| Fetch or verify failure | Item marked failed, batch continues; never registry-recorded, never deletable |
| Destination disk full | Pre-checked before copying (plan-then-act) |
| App crash mid-batch | Staging lives under `.openphoto/` → half-files never enter the library; next scan sees only verified placements |
| Deletion failure on device | Listed per item; registry unaffected (item remains "imported") |

## 7. Testing

- `ImportEngine` + `ImportRegistry`: full TDD with `FakeSource` (controllable failures) — dedup-skip, name collisions, Live-pair atomicity, verify-failure path, interrupted batch, registry round-trip, delete-only-verified invariant
- `VolumeSource`: generated fixtures (no hardware)
- `CameraSource`: thin; validated by a manual hardware checklist with Jude's iPhone (lock/unlock, enumeration, import, deletion happy/failure paths), like Phase 1's validation
- No test ever touches real user folders — generated media in repo/temp dirs only

## 8. Format-doc changes (same commit as the implementing code)

- New §12: `imports.jsonl` schema and semantics
- `.openphoto/staging/` — transient, readers MUST ignore
- `.openphoto-trash/` convention for removable volumes
- §9 `sync-log.jsonl`: add `import` and `device-delete` event examples
