# OpenPhoto — Requirements (as provided by Jude, 2026-06-07)

**Name:** OpenPhoto
**Repo:** https://github.com/jude-sph/OpenPhoto.git
**Platform:** macOS (MacBook Pro M4 Pro)

## Core philosophy

- Complete sovereignty over photos. Following the Obsidian philosophy: forward compatibility, simplicity, plain folder structure.
- The original files in `~/Pictures` and `~/Movies` are **never modified or moved** by the app without explicit user action.
- All app-generated data lives in **sidecars or a rebuildable SQLite index**.
- The library must remain **fully usable and browsable with the app deleted**.

## Storage & library

- Photos stored locally **as-is**, in existing user folders (e.g. `rome2022`, `canada23`). Keep this structure.
- Folders are arbitrary — not necessarily trips (e.g. `mac-screenshots`), and **may be nested**. The app must not assume folder = event.
- Videos live mixed with photos in their folders (the folder is the unit, not the media type); `~/Movies` is just another library root.
- View the whole "camera roll" over time (merged across folders) **and** view by folder.
- Sidecar metadata, never touch the originals — tags/names/ratings go to `.xmp` sidecars (digiKam/Lightroom convention) or the SQLite index, so `~/Pictures` stays pristine and portable.
- Need a way to keep track of photo ID if a file moves or gets renamed (or determine whether this is needed at all).
- Live Photos support.
- Video support.
- **Never hard delete** — send to macOS Trash or an app bin folder, with easy restore.

## Devices & syncing (hard problem — think deeply)

- Devices: Mac (viewer/manager), iPhone + camera SD cards (capture devices), external hard drives (canonical storage / backups).
- Flow: **one-way** from phone/SD card → Mac; **one-way** from Mac → canonical drive.
- Canonical drive's photos viewable when plugged into the Mac; some photos may live on Mac **and** drive; drive could optionally be exposed via a server.
- Mac can also pull photos back from the drive (rare).
- Mac can optionally itself be the canonical location; libraries can be **migrated** between canonical locations (one at a time, possibly multiple backups).
- Import from phone/SD is **slow and purposeful**: big grid of large photo thumbnails, user chooses which to move. Happens ~once per month.
- Possibly a **sync state artifact** to track things. Consider building on existing tools like rsync.
- Workflow: plug in phone via USB-C → import to Mac → delete from phone → later plug in canonical drive → sync new photos to it.

## Features

- Nice, simple, modern macOS design.
- Deduplication assistance.
- Metadata viewing **and editing**.
- Smart search across the library.
- **All intelligence runs locally** (face grouping, smart search, etc.).
- Map view using photo GPS metadata.
- On-device OCR search (Vision / `VNRecognizeTextRequest`) — find whiteboards, receipts, signs by text.
- Face/person grouping like Apple Photos (albums by person, files stay where they are) with: adjustable clustering thresholds, merge/split clusters, visible confidence scores.
- Consider (not 100% necessary): local LLM/semantic search — e.g. "me and my girlfriend at a restaurant in Taipei".
