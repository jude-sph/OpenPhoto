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

## Re-verify "sent to device" Locations on connect
*Needs a physical iPhone (or an SD card / USB volume) you've previously **Sent** photos to.
Read-only on the device — the connect re-verify only re-enumerates (`enumeratePresent()`),
never writes to the device.*

- [ ] **Send** a few photos to the device, confirm the inspector **Locations** shows "sent <date>".
- [ ] **Disconnect, then reconnect** the device — for photos still present, the indicator upgrades to **"on this device, confirmed <date>"** (green check).
- [ ] **Delete one of those photos off the device**, then reconnect — its indicator **downgrades to "sent <date> — no longer on the device"** (muted/orange), while still-present ones stay **"on this device (confirmed)"**; and if the deleted one was the only backup, the photo reverts to only-on-this-Mac (the only-copy warning returns).
- [ ] Confirm **nothing is written to the device** during re-verify (read-only re-enumeration) and that an **unconnected** device's indicator is unchanged ("sent <date>").

---

*Notes:* the Phase 3.5 video-player overhaul, folder toggles, dividers, and tile/badge
changes were verified live during development and are **not** on this list. iPhone
import/send AirDrop behaviour was proven by spikes (`docs/spikes/`) but not re-checked
against the shipped UI — listed above for a final pass.

---

## Slice A — Configurable library root

- [ ] **First run shows Welcome.** On a clean install (or after `defaults delete dev.jude.openphoto libraryRootPaths`), the app opens to the Welcome screen rather than the main UI.
- [ ] **Choose folder → open library.** Pick `~/Pictures` (or a fixtures folder) on the Welcome screen; the timeline appears without a restart.
- [ ] **Switch root via Settings.** Open Settings (⌘,) → Library tab → **Change…** → pick a different folder → confirm the alert. The old folder's photos leave every view; the new folder's photos appear — with no app restart.
- [ ] **Authored metadata survives a switch and switch-back.** Add a caption or favorite on a photo from folder A. Switch to folder B, then switch back to A. Confirm the caption/favorite is still present (metadata lives in XMP sidecars, not in the catalog).
- [ ] **Missing-root fallback.** Configure a root, quit, rename or delete the folder, relaunch. The app shows the Welcome screen rather than crashing or showing an empty timeline. The configured path is not forgotten (it reappears in Settings if the folder is restored).

## Slice B — Packaging, install & icon

- [ ] **`install.sh` puts a launchable app in `/Applications`.** Run `./scripts/install.sh`; confirm `/Applications/OpenPhoto.app` exists and launches cleanly.
- [ ] **Icon in Dock.** The Dock shows the OpenPhoto glyph (not a blank white square or generic app icon).
- [ ] **Icon in minimized/Stage-Manager strip.** Minimize the window (⌘M) and confirm the minimized-window thumbnail shows the OpenPhoto glyph, not a blank square.
- [ ] **DMG drag-install.** Run `./scripts/make-dmg.sh`. Mount the resulting `build/OpenPhoto-<version>.dmg`. Confirm it shows the app, an Applications symlink, and `READ ME FIRST.txt`. Drag-install the app and confirm it launches.

## Slice C — Self-update (Sparkle)

- [ ] **Older build detects a newer release.** Install a known-older build (lower build number / version). Launch it and use **App menu → Check for Updates…**. Confirm Sparkle shows a prompt offering the newer version.
- [ ] **One-click update installs and relaunches.** Click **Update** in the Sparkle prompt. The app downloads the new version, closes, and relaunches at the updated version — confirm via **App menu → About OpenPhoto**.
- [ ] **No second "Open Anyway" after update.** After the Sparkle-installed update relaunches, macOS must not show a Gatekeeper warning. (Sparkle strips the quarantine attribute from updates it installs.)
- [ ] **"Check for Updates…" works on demand.** When already on the latest version, the item opens Sparkle's dialog reporting that the app is up to date.
- [ ] **Tampered archive rejected.** Modify a byte in a `.zip` release archive (locally) and point a test appcast at it. Confirm Sparkle refuses to install it with a signature error rather than silently installing the corrupt file.
