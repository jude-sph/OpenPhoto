# OpenPhoto

A native macOS photo manager built on one promise: **the library is just files.**

Your photos and videos live in your own folders (`~/Pictures`, `~/Movies` — arbitrary names, arbitrary nesting), exactly as they are. OpenPhoto indexes, views, imports, and syncs — but the library remains fully usable and browsable with the app deleted. The Obsidian philosophy applied to photos: plain files, open formats, no lock-in.

## Status

**Phases 1–2** — browse + device import implemented; Phases 3–5 designed. Phase 1: library indexing (content-hash identity, manifest, rebuildable catalog), timeline, folder tree, viewer, inspector with XMP-sidecar metadata editing, bin. Phase 2: import from iPhones (ImageCaptureCore) and SD cards / arbitrary folders, with staged copy, hash verification, durable import registry, and opt-in free-up-phone flow — see `docs/`.

## Build & run

Requires macOS 15+ and Command Line Tools (no Xcode needed).

```bash
swift test                 # run the test suite
swift run OpenPhotoApp     # run the app directly
scripts/make-app.sh        # assemble build/OpenPhoto.app
```

First launch asks you to choose your library folders. To try it with a synthetic library instead of real photos:

```bash
swift scripts/gen-fixtures.swift 300   # generates ./fixtures-library
```

then point the welcome screen at `fixtures-library/`.

## Documentation

- `docs/superpowers/specs/2026-06-07-openphoto-design.md` — full architecture design
- `docs/format/vault-format-v1.md` — **the on-disk format, documented as a normative spec** for third-party implementors
- `docs/SPECS.md` — original requirements
- `CLAUDE.md` — project invariants and documentation discipline

## The invariants

1. Original media files are never modified or moved without explicit user action.
2. Human-authored metadata lives in standard XMP sidecars beside the files; machine-derived data lives in a rebuildable catalog.
3. Nothing hard-deletes — deletion moves files to a bin, emptying the bin moves them to macOS Trash.
4. All vault-state writes are atomic; all copies are hash-verified.
