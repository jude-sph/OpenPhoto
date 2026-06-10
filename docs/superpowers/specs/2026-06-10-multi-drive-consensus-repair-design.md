# Multi-drive consensus repair (in Verify Integrity) — design

**Date:** 2026-06-10
**Branch:** `multi-drive-consensus-repair` (off `main`)
**Status:** Approved
**Builds on:** Phase 3 Slice 2 (drift/integrity — `DriftReconciler.scan`/`verify`, `DriftReport`, `DriftReviewSheet`, `AppState.verifyIntegrity`/`driftScan`, `PresenceService` recoverability, `goodCopyURL`/`restoreOne`), `VerifiedCopy`, `BinStore`. Carved out of Phase 3.5.

> The feature the user pulled out of Phase 3.5: *"when Check / Verify Integrity finds drift or bit-rot, use the other connected drives + the Mac as repair sources — surface drift across all connected drives at once and offer one-click repair from a verified-good copy."*

---

## 1. The gap (what exists vs. what's new)

Today's Verify is **per-drive** and only **missing** files are repairable:

- `verify(drive:)` re-hashes every file → `DriftReport` with `missing` / `changed` / `corrupt` / `unknown`. **`corrupt` is detected but report-only** (no repair action).
- `restoreOne` repairs a **missing** file: `goodCopyURL(forHash:excluding:)` finds a reachable copy (the Mac, or any connected durable drive holding the hash), then `DriftReconciler.restore` does a `VerifiedCopy` (re-hash on copy → a rotten source **fails safe**).

**New in this slice:**
1. **Repair corrupt (bit-rot) files** — the real new capability (today they're report-only).
2. **Cross-drive sweep** — verify every connected durable drive at once and repair across the whole set in one pass.

Scope, settled in brainstorming: repair covers **corrupt + missing**. **Changed** stays manual (Adopt / Acknowledge) — a changed file may be a legitimate edit, and auto-reverting it could discard intended content.

---

## 2. How corrupt vs. changed is decided (existing engine, recap)

Both mean "the file's bytes no longer hash to the manifest." The split (from `DriftReconciler.verify`: `sameSizeAndTime ? .corrupt : .changed`):

- **corrupt** = hash differs **but size + mtime still match** the manifest → nothing *should* have touched the file (silent bit-rot / bad sector). The manifest hash is the truth → reverting to a verified-good copy is unambiguously correct.
- **changed** = hash differs **and** size or mtime moved → something actively wrote to it (an edit) → not auto-reverted.

Only the full **Verify** (re-hash) can detect `corrupt`; the fast **Check** (`scan`) trusts size+mtime and can only ever produce `changed`. So consensus repair lives on **Verify Integrity**.

---

## 3. The model — canonical-authoritative, not a vote

A file's *expected* hash is **its own drive's `manifest.jsonl` entry** (for a synced drive this equals the canonical's; the canonical is the authority). A repair **source** is **any connected copy — the Mac or another durable drive — whose bytes hash-match that expected hash**; `VerifiedCopy` re-hashes on copy, so a rotten source fails safe. No majority vote, no quorum.

Consequence (the real win): **the canonical itself can be repaired from a backup** — if a canonical file rots, a backup whose bytes still match the canonical's manifest hash is a valid source. `goodCopyURL` already searches the Mac + every connected durable drive, so this works for any drive including the canonical.

Files with **no good copy anywhere** (`recoverability == .lostNoCopy`) are surfaced as **lost** (red), not repaired.

---

## 4. Core — one new repair primitive (TDD)

`DriftReconciler.repairCorrupt(finding:expectedHash:from source:on drive:)` — repair a corrupt file with the **bin-then-replace** safe ordering, so we never bin the rotten file until a verified replacement is staged:

1. **Stage + verify:** `VerifiedCopy.copy(from: source, to: tempURL, expectedHash: H)` into a temp under the drive's `.openphoto/` (same volume as the destination). If it returns false (a rotten/short source), **throw — nothing is binned**, the slot is untouched.
2. **Quarantine the rotten file:** `BinStore(vault: drive).moveToBin(relPath:, hash: H, origin: .repaired)` — the corrupt original moves to the drive's `.openphoto/bin/`, recoverable.
3. **Place:** atomically rename `tempURL` → the destination slot (same volume → atomic).
4. **Re-record:** `writeManifestEntry(hash: H, …)` updates the entry's **size + mtime** to the freshly-placed file (hash unchanged = H), so a subsequent Check sees it clean.

`VerifiedCopy` and `BinStore` are reused **unchanged** except for one small addition (below). Missing-file repair keeps the existing `restore` path (its slot is already empty, so no binning needed).

**On-disk format addition (documented in the same commit):** `BinStore.Origin` gains a **`repaired`** case (today: `user` / `propagated`). This keeps a repaired-out corrupt file cleanly distinct from a user/propagated deletion — it's quarantined damaged bytes, **never** treated as a pending deletion or propagated. Update `docs/format/vault-format-v1.md` §8 (bin origins) accordingly. No manifest/catalog schema change.

---

## 5. App — the cross-drive sweep + repair actions

- **Entry point:** a **"Verify All Drives"** button in the Drives panel toolbar (next to "Add Drive…" / "Quick View Folder…").
- **`AppState.verifyAllConnected(progress:)`** — runs `verify` on **every connected durable drive** (canonical + backups) off-main, with progress (drive name + per-file). Annotates `recoverability` **across the whole connected set** (a corrupt file on drive A is "recoverable from B / Mac" when they hold the matching bytes — `goodCopyURL`/`PresenceService` already span all connected drives). Returns a per-drive `[VaultRecord: DriftReport]`-style result.
- **Combined review sheet** (a new `ConsensusRepairSheet`, mirroring `DriftReviewSheet`'s list idiom) — findings **grouped by drive**:
  - **corrupt** and **missing** → a **Repair** button (and a per-drive / whole-set **"Repair all recoverable"** that sweeps in one confirmed pass);
  - **changed** / **unknown** → today's Adopt / Acknowledge (unchanged);
  - `lostNoCopy` → shown **lost** (red), no repair button.
  Each repair re-scans the affected drive and refreshes presence/badges; the sheet updates in place. Idempotent — re-running finds nothing to do.
- **`AppState` repair actions:** `repairCorruptOne(finding:on:)` (BinStore-quarantine + `DriftReconciler.repairCorrupt`, off-main) and a `repairAllRecoverable(...)` that handles corrupt (repairCorrupt) + missing (existing restore) across a drive or the whole set. One **confirmation** for a bulk repair ("Repair N corrupt + M missing across K drives from verified-good copies?").
- **Consistency:** the existing **per-drive `DriftReviewSheet` also gains the corrupt Repair button** (it currently lists corrupt as report-only), so the per-drive and all-drives surfaces behave the same.

---

## 6. Data flow

"Verify All Drives" → per-drive `verify` (off-main, progress) → cross-set recoverability annotation → combined sheet grouped by drive → user clicks **Repair** (one file) or **Repair all recoverable** (confirmed) → for each: `goodCopyURL(forHash:excluding: thatDrive)` → `repairCorrupt` (corrupt: stage+verify → bin rotten → place → re-record) or `restore` (missing) → re-scan that drive → refresh presence/badges/sheet. The live catalog's `vault_presence` follows verified reality (as drift/verify already do).

---

## 7. Error handling / edge cases

| Case | Behavior |
|---|---|
| Rotten/short repair source | `VerifiedCopy` fails → `repairCorrupt` throws **before** binning → slot untouched, finding stays; try another source if one exists. |
| No good copy anywhere | `lostNoCopy` → surfaced **lost** (red), no repair offered. |
| Source drive ejected mid-repair | The copy fails → throws before binning → safe; sheet's next re-scan reflects what's connected. |
| Interrupted between bin and place | Temp file is verified; on next Verify the slot reads **missing** and the verified bytes still exist on a good copy → repairable again. (Bin holds the rotten original.) |
| Canonical file corrupt, backup good | Repaired from the backup (its bytes match the canonical's manifest hash). |
| Re-run after a clean repair | Idempotent — nothing to repair. |

---

## 8. Testing

**Core (TDD, temp dirs + generated mock media + temp vaults, never `~/Pictures`):**
1. `repairCorrupt` happy path — a corrupt file + a good source → file matches the manifest hash again, the **corrupt original is in the drive bin** (`origin: repaired`), the manifest size/mtime re-recorded, hash unchanged.
2. **Rotten-source safety** — a source whose bytes *don't* hash to `H` → `repairCorrupt` throws, the **original is NOT binned**, the slot is unchanged (the invariant the user cares about).
3. Cross-set recoverability — a corrupt file on drive A is `.recoverable` when drive B (or the Mac) holds the hash; `.lostNoCopy` when nobody does.
4. `BinStore.Origin.repaired` round-trips through `bin.jsonl`.

**App:** build-verified (0 warnings) + manual — Verify All Drives across a multi-drive set; corrupt repair from another drive (incl. repairing the canonical from a backup); missing repair; "lost" surfaced not repaired; per-drive Verify sheet's new corrupt Repair button; rebuild bundle.

---

## 9. Task decomposition (for the plan)

1. **Core (TDD)** — `BinStore.Origin.repaired` (+ format doc §8); `DriftReconciler.repairCorrupt` (bin-then-replace safe ordering) with the rotten-source-safety test.
2. **App** — `AppState.verifyAllConnected` + `repairCorruptOne` + `repairAllRecoverable` (corrupt + missing, off-main); add the corrupt **Repair** button to the existing `DriftReviewSheet`. Build-verified.
3. **App** — the cross-drive **`ConsensusRepairSheet`** (grouped by drive, repair actions, bulk repair with one confirmation) + the **"Verify All Drives"** Drives-panel entry point. Build-verified + manual; rebuild bundle.
4. **Docs** — `docs/format/vault-format-v1.md` §8 (the `repaired` bin origin); master spec §10 + changelog (consensus repair done; Phase 3 drives fully closed out → next is **Phase 4 (Intelligence)**).

No catalog/manifest schema change. The `SyncEngine` copy spine, `Manifest`, and send destinations are untouched; this composes `VerifiedCopy` + `BinStore` + the existing drift engine.
