# Spike: iPhone deletion via ImageCaptureCore — findings

**Date run:** 2026-06-08
**Device:** Jude's iPhone (iCloud Photos **ON**), connected via USB-C, 4,357 items visible
**Host:** macOS 15.2, CLT 16.2, `ICCSpike` target (`swift run ICCSpike [--download-first|--delete-newest]`)

## Results

| Step | Result |
|---|---|
| Enumeration (locked phone) | **Session refused** — error `-9943` "Please unlock". `cameraDeviceDidEnableAccessRestriction` fires. |
| Enumeration (unlocked) | **Works.** `deviceDidBecomeReady(withCompleteContentCatalog:)` delivers all 4,357 items with names, sizes, capture dates. Item order is NOT chronological. |
| Unlock-while-waiting | **Works.** `cameraDeviceDidRemoveAccessRestriction` fires on unlock; re-requesting the session succeeds. No replug needed. |
| Download | **Works.** `requestDownloadFile` with `.downloadsDirectoryURL`; byte size matches enumeration exactly (verified twice: 856,588 B and 2,888,127 B files). |
| **Deletion (iCloud Photos ON)** | **SUCCEEDED.** `requestDeleteFiles` on the newest capture completed with no error via `cameraDevice(_:didCompleteDeleteFilesWithError:)` within seconds. |

## Conclusions for Phase 2 (import flow)

1. **"Delete from iPhone after verified import" is viable** — even with iCloud Photos enabled, on this device/iOS version. The spec §11 risk ("iOS restricts deletion when iCloud Photos is enabled") did **not** materialize here; treat deletion as supported-but-verify: attempt it, and surface a clear per-item failure list if a different configuration refuses.
2. **The import UI must handle the locked state as a first-class flow**: session open fails with `-9943` while locked; wait for `cameraDeviceDidRemoveAccessRestriction` and retry rather than erroring out. (Pattern implemented and proven in the spike.)
3. **Order is not chronological** — the import grid must sort by `creationDate`, not enumeration order.
4. **The download→verify→delete ritual works exactly as the design specs it** and should be lifted into the Phase 2 importer: `requestDownloadFile` → hash/size verify on disk → only then `requestDeleteFiles`.
5. **Verified by Jude on-device:** USB deletion **bypasses "Recently Deleted" entirely** — the photo is gone immediately and permanently from the phone. ImageCaptureCore/PTP deletes at the media-store level, not through the Photos app's soft-delete flow. Consequence for Phase 2: the verified Mac copy is the ONLY copy after deletion, so the import flow's checksum-verify-before-delete step is not optional politeness — it is the sole safety net, and the UI must say plainly that deletion from the phone is immediate and permanent (no on-device undo).

## Raw output (deletion run)

```
Found: jude’s iPhone — opening session…
Access restriction enabled (device locked).
Phone is locked. Waiting — unlock it and I'll retry automatically…
Access restriction removed (device unlocked) — retrying session…
Session open. Waiting for contents…
Items visible: 4357
Newest item: IMG_6385.HEIC  2888127 bytes  taken 2026-06-08 01:15:58 +0000
Step 1: downloading backup copy…
Download SUCCEEDED → spike-download/IMG_6385.HEIC
Step 2: requesting deletion of IMG_6385.HEIC from the phone…
RESULT: deletion SUCCEEDED (didCompleteDeleteFilesWithError, no error)
```
