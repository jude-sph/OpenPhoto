# OpenPhoto

A native macOS photo manager built on one promise: **the library is just files.**

Your photos and videos live in your own folders (`~/Pictures`, `~/Movies` — arbitrary names, arbitrary nesting), exactly as they are. OpenPhoto indexes, views, imports, and syncs — but the library remains fully usable and browsable with the app deleted. The Obsidian philosophy applied to photos: plain files, open formats, no lock-in.

## Status

**Phases 1–2 implemented (plus a library-management feature on top); Phase 3 in progress (Slice 1 done); Phases 4–5 designed.**

- **Phase 1 — Browse:** library indexing (content-hash identity, manifest, rebuildable catalog), timeline, folder tree, viewer, inspector with XMP-sidecar metadata editing, bin.
- **Phase 2 — Import:** import from iPhones (ImageCaptureCore) and SD cards / arbitrary folders, with staged copy, hash verification, a durable import registry, and an opt-in free-up-phone flow.
- **Library selection · evict · send · locations** (built after Phase 2): multi-select in the timeline and folders (click / shift / rubber-band, with pinch-to-zoom and edge auto-scroll); **evict** to the recoverable bin with an "only-copy" warning; **send to a device** — back to an iPhone via AirDrop (confirmed by re-enumerating the phone) or to an SD/USB volume by hash-verified copy — tracked in `sends.jsonl`/`devices.jsonl`; and a **Locations** inspector panel showing everywhere a photo is known to exist (This Mac / phones / cards) with confidence.
- **Phase 3 — Drives (in progress):** Slice 1 — additive one-way sync (Mac → canonical drive): adopt a drive, preview a plan, hash-verified atomic resumable copy that never overwrites, and a "backed up on canonical" badge. See `docs/superpowers/specs/2026-06-09-phase3-drives-design.md`.

See `docs/` for the designs and hardware-spike findings.

## Build & run

Requires macOS 15 (Sequoia) or later, on Apple Silicon or Intel Macs (universal binary). Command Line Tools only — no Xcode needed.

```bash
swift test                 # run the test suite
swift run OpenPhotoApp     # run the app directly
scripts/make-app.sh        # assemble build/OpenPhoto.app
```

First launch asks you to choose your library folder. To try it with a synthetic library instead of real photos:

```bash
swift scripts/gen-fixtures.swift 300   # generates ./fixtures-library
```

then point the welcome screen at `fixtures-library/`.

## Install / Build / Release

### Scripts

| Script | Purpose |
|---|---|
| `scripts/install.sh` | Build and install to `/Applications/OpenPhoto.app` (your stable personal copy). Refreshes Dock and icon caches. |
| `scripts/make-dmg.sh` | Build a shareable `build/OpenPhoto-<version>.dmg` with a drag-to-install layout. Send this to anyone who wants to try OpenPhoto. |
| `scripts/release.sh` | Publish a new version for everyone: builds artifacts, signs and regenerates the Sparkle appcast, creates a GitHub Release, and pushes the updated appcast to GitHub Pages. |

### Sharing the app

See **[docs/DISTRIBUTING.md](docs/DISTRIBUTING.md)** — what file to send, how recipients install it (including the one-time Gatekeeper "Open Anyway" step on macOS 15+), and how automatic updates work for them.

### Publishing a new version

See **[docs/RELEASING.md](docs/RELEASING.md)** — one-time developer setup (EdDSA key generation, GitHub Pages, `gh` CLI), the per-release checklist (bump `VERSION`, run `release.sh`, verify the live appcast), and troubleshooting.

## Documentation

- `docs/superpowers/specs/2026-06-07-openphoto-design.md` — full architecture design (phases, sync engine, intelligence) + changelog
- `docs/superpowers/specs/2026-06-08-phase2-import-design.md` — Phase 2 device-import design
- `docs/superpowers/specs/2026-06-08-library-selection-evict-send-design.md` — selection, evict & send-to-device design
- `docs/format/vault-format-v1.md` — **the on-disk format, documented as a normative spec** for third-party implementors (manifest, sidecars, bin, registries §12–§14)
- `docs/spikes/` — hardware investigation findings (ICC deletion, AirDrop placement + byte-for-byte round-trip, dense-grid compositing lag)
- `docs/SPECS.md` — original requirements
- `CLAUDE.md` — project invariants and documentation discipline

## The invariants

1. Original media files are never modified or moved without explicit user action.
2. Human-authored metadata lives in standard XMP sidecars beside the files; machine-derived data lives in a rebuildable catalog.
3. Nothing hard-deletes — deletion moves files to a bin, emptying the bin moves them to macOS Trash.
4. All vault-state writes are atomic; all copies are hash-verified.
