# Foreign Imports (other people's libraries) — Design

**Status:** approved direction (Jude, 2026-06-12), spec pending Jude's review. Phase 5.5 slice 2.

**Goal:** Import photos from libraries that aren't yours: (A) another person's **OpenPhoto drive** (canonical or backup) plugged into your Mac, browsed per-folder; (B) a friend's **Apple Photos library on their Mac**, crossed over as an exported folder. Driving real case: a friend's ~10k photos/videos, of which ~6–7k should enter Jude's library.

**Architecture in one line:** one new read-only `ImportSource` (`ForeignVaultSource`, enumerating from the foreign drive's *documented* manifest/snapshot formats) plus scale-and-metadata upgrades to the existing folder import — all feeding the unchanged ImportEngine pipeline (copy → hash → dedup → place → rescan → verify → registry).

---

## 1. Scope & decisions (from the brainstorm)

- **Friend's Mac = export-based transport, no library parsing.** PhotoKit can only open the Mac's *own* system library, and parsing a copied `.photoslibrary`/Photos.sqlite is reverse-engineering a private, version-shifting format — rejected. The friend's Photos app is the exporter; OpenPhoto is the importer. (Jude, Q1: "Workflow + XMP fold".)
- **Foreign OpenPhoto drives auto-appear in the sidebar** (Jude, Q2): a mounted volume whose root carries `.openphoto/vault.json` with a vaultID that is neither a local vault nor a registered durable drive shows up under Devices as an import source. Adoption-as-my-mirror stays where it is today (explicit Add Drive + confirmed prompt) — no accidental merging of someone else's library.
- **Curation happens in the import grid** (Jude, Q3): the friend's 10k-item export is culled to 6–7k via Select All New + deselect. The grid and enumeration must be comfortable at 10k — a hard requirement of this slice.
- **"Include their metadata" is a per-import toggle, default OFF** (Jude, Q4): off = files only; on = their human metadata comes along (mechanics in §4/§5).
- **Foreign-vault folders land with their tree intact under a chosen parent** (Jude, Q5): e.g. `From Sam/rome2022/…`. Quarantined under one root, dissolvable later with the move tools.
- **The friend's export lands flat** into one destination folder (Jude, Q6) — like every import so far; Apple's "Moment Name" subfolders are discarded; organize afterwards with select & move.
- **No on-disk format change, no catalog schema change.** This slice *reads* our documented formats (manifest, snapshot) from foreign media; it writes nothing new.

---

## 2. `ForeignVaultSource` (Core, new) — read-only ImportSource over someone else's vault

Opened via the existing `Vault.open` (read-only; never writes — their drive stays passive even though it's not ours).

### Enumeration — from the documented formats, not a 10k-file walk
- **Inventory:** their `manifest.jsonl` (vault-format §4) is authoritative: relPath, size, content hash, mtime per file. The per-folder tree derives from the path set instantly. Their `.openphoto/` internals (bin, sidecars, thumbs) never appear as media.
- **Capture dates / kinds:** when the drive carries a **catalog snapshot**, read it under the documented snapshot-reader rules in `catalog-schema.md` (assets table + that drive's `vault_presence` rows ONLY) — OpenPhoto becomes its own first third-party snapshot implementor. Fallback when absent (e.g. a backup without snapshot): manifest mtime, refined by the same cheap EXIF header read the folder source uses.
- **Pre-flag dedup with zero I/O:** the manifest's content hashes intersect with your catalog's hashes — "already in your library" badges appear before a single byte is copied. `ImportItem` gains an optional `knownHash`. **Sovereignty note:** the foreign hash is used only for *pre-flagging*; after copy, the engine still computes and verifies its own hash (invariant 4 — all copies hash-verified; we never trust foreign metadata for integrity).
- Live pairs: from snapshot pairing when available, else the existing basename pairing.

### Fetch / thumbnail / delete
- `fetch` = `copyItem` from the drive. Thumbnails via CGImageSource downsampling (as VolumeSource). `delete` returns "read-only" for every item; `reclaimableTrashCount`/`emptyTrash` protocol defaults.

---

## 3. Import screen — per-folder selection + destination parent

Shown only for `ForeignVaultSource`:

- **Folder panel:** their folder tree with checkboxes and item counts (derived from the manifest). The grid shows the union of checked folders' items; Select All New / rubber-band / shift behave as today within that filter. Default: nothing checked (you opt folders in).
- **Destination = parent picker:** the existing destination picker chooses the *parent* (default suggestion named after the drive, e.g. "From Sam"); imported items place at `parent/<their relPath within the checked tree>`.
- **"Include their metadata" toggle** (default off) sits beside the destination picker (also governs §5's fold for folder sources — one consistent control).

---

## 4. ImportEngine extension — per-item subpaths + post-place sidecar carry

- **Placement:** `run` gains an optional per-item destination subdirectory (default = the flat dirPath behavior, used by every existing source unchanged). For `ForeignVaultSource`, the subdir is the item's folder relative to the checked roots, under the chosen parent. Collision-free naming applies per destination directory; verify/registry record the placed relPath exactly as today.
- **Sidecar carry (toggle ON, OpenPhoto-drive source):** after place + verify, for each imported item the source's `.openphoto/<name>.xmp` is copied to the destination's sidecar path — renamed to match any collision-adjusted media name — then one rescan ingests it (sidecar stays the authoritative XMP form; media bytes untouched, hashes stable). Their favorites/ratings/captions/tags/face-name regions arrive intact. Toggle OFF: no sidecar is copied.

---

## 5. Folder import upgrades (the friend's-Mac path)

### 5.1 Scale: 10k items on external media
- `VolumeSource.enumerateItems` currently does a serial EXIF header read per photo — fine for an SD card, minutes for 10k files over USB. This slice: **bounded-concurrency enumeration** (TaskGroup) plus **progress reporting** surfaced in the import screen ("Reading 4,200 of 10,000…"), with the grid usable as soon as enumeration completes.
- Grid + selection verified at 10k: lazy rendering, O(1)-per-item selection ops, Select All New, large rubber-band deselects, and the size|capture-second "already imported" pre-flag. Core enumeration concurrency is TDD'd at modest scale with generated files; the full 10k experience is validated by Jude live.

### 5.2 Apple-export XMP fold (toggle ON, folder source)
- Apple Photos' **File → Export → Export Unmodified Originals** with **"Export IPTC as XMP"** writes a standard `.xmp` sidecar per photo. With the metadata toggle on, folder import parses the adjacent sidecar during fetch and **folds** it into the staged copy (Takeout-style: before hashing, via the existing `EmbeddedMetadata` fold), then the sidecar is never copied. Mapping: `dc:description`/`dc:title` → caption, `dc:subject` → tags, `xmp:Rating` → rating (the plan pins the exact field set from Apple's standard IPTC/XMP export vocabulary; tests use generated sidecars in that vocabulary — never real user data; Jude's live import is the real-sample check). Toggle OFF (default): `.xmp` files are skipped exactly as today.
- The toggle appears for folder sources when adjacent `.xmp` sidecars are detected during enumeration.

### 5.3 The documented friend workflow
On their Mac: select in Photos (all, or a People-album rough cut) → File → Export → **Export Unmodified Originals** (+ IPTC as XMP; Subfolder Format irrelevant — landing is flat). On your Mac: Add Import Folder → cull in the grid → import. Originals at full quality, EXIF dates, Live Photos as paired HEIC+MOV — all already supported.

**Transport (export target), ranked:** the export step is unavoidable — only their Photos app can read their library — but the target can be anything mountable, and import works on any mounted folder:
1. **External exFAT drive/SSD** (best when available): export unattended onto it, hand it over, import at full USB speed; re-export stragglers trivially.
2. **Thunderbolt cable between the Macs**: a plain USB cable can't link two hosts, but a Thunderbolt/USB4 cable brings up a *Thunderbolt Bridge* network — turn on File Sharing on the importing Mac and the friend exports straight into a shared folder there (~10–20 Gbps).
3. **File Sharing over Wi-Fi**: same flow, no cable, slower (fine when not in a hurry).
4. **AirDrop**: small top-up batches only — it stalls without resume on 10k-class transfers.

---

## 6. DeviceWatcher / sidebar

- New `ConnectedDevice.foreignVault(name:, rootURL:)`: on volume mount, if `Vault.open(at: volumeRoot)` succeeds and the vaultID is unknown (∉ local vaults ∪ registered durable drives), the volume surfaces as a foreign OpenPhoto drive (drive glyph + owner-ish name from the volume label). Detection precedence on a mounted volume: own registered drive (today's behavior) → foreign vault (new) → DCIM/plain volume (today's behavior).
- Removing/ejecting behaves like other devices. The remove-source gate in the sidebar treats it like other ephemeral sources.

---

## 7. Errors & edge cases

- Foreign drive disappears mid-import: per-item fetch failures collect into the existing failed-items reporting; nothing partial enters the library (staging + verify unchanged).
- Manifest entry whose file is missing on the drive (their drive drifted): item shows in the grid; fetch fails cleanly into failed-items.
- A foreign drive with no snapshot and no readable EXIF: items sort by mtime — degraded but functional.
- Their vault `format_version` newer than ours: refuse politely with the existing unsupported-version error surface.
- Two checked folders containing identical files (same hash, two paths): both import (they're distinct instances, same as your own library's duplicate-instance semantics).

---

## 8. Testing

Core TDD (generated media in TestDirs only — never real user data):
- `ForeignVaultSource`: manifest enumeration (tree derivation, `.openphoto` exclusion), snapshot-backed dates via the documented reader rules, knownHash pre-flag intersection, fetch/copy, read-only delete.
- Engine: per-item subpath placement (structure under parent, collision per-dir, flat default untouched — existing import tests stay green), post-place sidecar carry incl. collision-renamed names.
- Folder upgrades: concurrent enumeration correctness (same results as serial, order-stable), XMP sidecar parse + fold round-trip (embed → scanner reads back), toggle-off skip.
- DeviceWatcher foreign-vault detection precedence: app-layer, build-verified.
- Scale: enumeration concurrency + selection ops tested at modest scale; 10k validated live by Jude (his real import is the acceptance test).

---

## 9. Out of scope

Parsing `.photoslibrary` / Photos.sqlite; writing anything to a foreign drive (their bin, their sidecars, their manifest — all untouched); importing their face *database* (face names ride only in sidecars when toggled on); iCloud shared libraries / shared albums; importing from their **bin**; chunked/resumable mega-imports beyond 10k-class; adopting foreign drives (existing flow, unchanged).
