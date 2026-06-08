# Spike: AirDrop restore to iPhone — findings

**Date run:** 2026-06-08
**Device:** Jude's iPhone (iCloud Photos **ON**), macOS host
**Method:** Two generated mock images (no real user media) AirDropped Mac → iPhone, then "Save to Photos":
- **A** — `A-camera-2015.jpg`, 1200×1600, EXIF `DateTimeOriginal=2015:06:15`, TIFF `Make=Apple / Model=iPhone SE`, GPS = Paris.
- **B** — `B-screenshot-nodate.png`, 750×1334, **no metadata** (screenshot-shaped).

## Question

Can OpenPhoto put library photos *back* onto the iPhone so they appear in Apple
Photos **as if taken by the phone** — integrated into the timeline at their
original date — rather than quarantined in a separate read-only section?

## Results

| Check | Result |
|---|---|
| Lands in the real library (not a synced/read-only album) | **Yes** — both became normal, first-class library assets (favorite/edit/delete like any photo). |
| A sorts into the timeline at its **original capture date** | **Yes** — appears in the main Library back in **June 2015**, not at "today". |
| A shows device attribution + location | **Yes** — info panel shows **iPhone SE** and the **Paris** map pin, straight from EXIF. |
| B (no date metadata) placement | **Falls back to "today"** (date-added), as predicted. Otherwise a normal library asset. |

User confirmation (2026-06-08): "Works perfectly on all counts."

## Conclusions for the restore feature

1. **AirDrop → Save to Photos writes into the real Photos library.** This is the
   crucial difference from Finder/iTunes photo *sync* (which creates a separate
   read-only album and is disabled when iCloud Photos is on). AirDrop is viable.
2. **Timeline placement is driven entirely by embedded EXIF `DateTimeOriginal`.**
   Files with intact capture metadata integrate at their original date; files
   lacking it (some screenshots, metadata-stripped exports) fall to "today".
   AirDrop forwards original bytes — it cannot add a date the file doesn't carry.
3. **Device + GPS attribution display natively** from EXIF. For photos that
   *originated from an iPhone* (the primary use case — putting back what we
   imported) this is already correct. We will **NOT fabricate** Make/Model/GPS
   for photos from other sources — honest metadata only.
4. **Remaining caveats (accepted):**
   - **Live Photo motion is lost** — the still is restored, not the live motion
     (consistent with [icc-deletion spike]: motion isn't available over USB either).
   - **No programmatic confirmation** of what landed — AirDrop returns no receipt,
     so the restore registry is **best-effort** ("sent", not "confirmed present").
   - **Manual accept** per AirDrop batch (one "Save N items" tap on the phone).
5. **Future option:** a companion iOS app (PhotoKit `PHAssetCreationRequest`)
   could SET creation date explicitly (fixing caveat for metadata-thin files),
   rebuild real Live Photos, and confirm-back exactly what was saved. AirDrop is
   sufficient for first-class, date-correct restore of normal photos with **no
   new app to build, sign, or install** — the right first version.

## Round-trip identity finding (2026-06-08)

**Question:** does a photo survive library → AirDrop → Apple Photos → re-import
over USB **byte-for-byte**? If yes, our existing content-hash dedup recognizes a
sent-then-reimported photo automatically (it won't masquerade as a new photo,
regardless of its original source).

**Method:** re-downloaded the two already-AirDropped test files from the phone
via ImageCaptureCore and compared SHA-256 to the originals we sent.

| File | Original sha256 | Re-imported sha256 | Size | Result |
|---|---|---|---|---|
| A (`A-camera-2015.jpg`) | `29981775…` | `29981775…` | 31853 → 31853 | **IDENTICAL** |
| B (`B-screenshot-nodate.png`) | `9f42b315…` | `9f42b315…` | 21191 → 21191 | **IDENTICAL** |

**Findings:**
1. **Bytes are preserved exactly.** AirDrop sends the original, Photos stores the
   original master untouched, and ICC hands it back unchanged. So **content-hash
   identity is round-trip stable** → the existing import dedup (`hashPresent`) is
   the authoritative mechanism for "we already have this," source-agnostic. A
   photo from an SD card that we sent to the phone is recognized on re-import by
   its hash; it never looks like a new iPhone photo.
2. **Filenames are NOT preserved.** Apple Photos rewrote the saved assets to
   random 8-char names (`A-camera-2015.jpg` → `IQUN7722.JPG`,
   `B-screenshot-nodate.png` → `UNUM9460.PNG`). **Consequence for the design:**
   the cheap phone-side fingerprint used for log reconciliation and import-grid
   labelling must key on **byte size + capture date**, NOT filename. (The
   authoritative content-hash check at download time backstops collisions.)
3. **Capture date is preserved** (A re-imported with its 2015 date), consistent
   with the placement finding above. B (no EXIF) carries the date-added.

**Design conclusion:** two-layer dedup is sound. Layer 1 (content hash) is
rock-solid and authoritative. Layer 2 (size+date fingerprint via the send log)
is the cheap pre-download label so sent photos never *appear* new in the import
grid. Filename is unusable as an identity key across the round trip.
