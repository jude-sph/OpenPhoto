# Manual / hardware test checklist (run before release)

These are tests that **can't be unit-tested** — they need physical devices (external
drives, iPhones, SD cards) or a human's eyes — and have been **deferred to the end of
development**. The automated suite (`swift test`) covers the logic and the safety
invariants; this list verifies end-to-end behavior on real hardware.

Check items off as they're verified. Add new deferred hardware/manual tests here as
features land.

---

## Multi-drive consensus repair (Verify Integrity)
*Needs ≥2 connected durable drives (canonical + a backup) and an induced corruption
(e.g. flip a few bytes of a file on a drive without changing its size/mtime).*

- [ ] **Verify All Drives** runs across the 2+ drive set with per-drive progress.
- [ ] A corrupt file shows `corrupt … from <other drive / This Mac>` + a **Repair** button.
- [ ] Repairing swaps in the good bytes and moves the rotten file to the drive's bin (`origin: repaired`); the manifest still records the correct hash; a follow-up Check is clean.
- [ ] **Repairing a corrupt file on the *canonical* from a *backup*** works (the marquee case).
- [ ] A **missing** file repairs from a connected good copy.
- [ ] A file with **no good copy anywhere** is surfaced **lost** (red), with no Repair button.
- [ ] **Repair all** confirms, then sweeps the whole connected set; re-running is idempotent (nothing to do).
- [ ] The **per-drive** Verify Integrity sheet's new corrupt **Repair** button behaves the same.
- [ ] A rotten/short repair source (e.g. eject the source drive mid-repair) fails safe: the slot is untouched, nothing binned.

## SD-card / volume "Send"
*Needs a removable SD card or USB volume.*

- [ ] **Send** photos from the Mac/a drive to a mounted SD card / USB volume — the hash-verified copy lands, already-present files are skipped (dedup), and the send is journaled in `sends.jsonl`.

## iPhone import / send (AirDrop)
*Needs a physical iPhone.*

- [ ] **Delete from iPhone** after a verified import (ImageCaptureCore `requestDeleteFiles`) — confirm it removes the imported originals; per-item failures surface gracefully (locked-phone retry).
- [ ] **Send to iPhone via AirDrop** — photos land at their original capture date and round-trip byte-for-byte; the send is verified by re-enumeration and journaled.

---

*Notes:* the Phase 3.5 video-player overhaul, folder toggles, dividers, and tile/badge
changes were verified live during development and are **not** on this list. iPhone
import/send AirDrop behaviour was proven by spikes (`docs/spikes/`) but not re-checked
against the shipped UI — listed above for a final pass.
