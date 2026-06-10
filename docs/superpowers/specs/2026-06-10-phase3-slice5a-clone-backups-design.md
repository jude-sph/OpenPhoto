# Phase 3 Slice 5a — Clone + First-Class Backups + Durable Deletion Propagation (design)

**Date:** 2026-06-10
**Branch:** `phase3-drives`
**Status:** Approved
**Builds on:** Slice 1 (`SyncEngine.plan`/`apply`, `VerifiedCopy`, `Manifest`, `DriveVolume`, `vault_presence`), Slice 2 (`DriftReconciler`), Slice 3 (`DeletionPropagator`, `pending_deletions`, Review-Deletions gate), Slice 4 (`evict`/`rehydrate`, `verifyOnCanonical`), Slice 4.5 (send-from-drive).

> **Slice 5 is split into three sub-slices** (build order): **5a (this spec)** — clone + backups as first-class durable copies + durable deletion propagation; **5b** — catalog-snapshot write (+ `catalog-schema.md`) + fresh-Mac adoption; **5c** — migration (clone + role flag-flip). 5a establishes the backup foundation that 5b and 5c compose on.

---

## 1. Goal

Make the canonical library **redundant** by cloning it to backup drives and **keeping those backups current** over time — additions and deletions — while honoring the model recorded in master-spec §5.4:

> The canonical is the source of truth; backups are derived from it. Reads treat all connected durable drives (canonical + backup) as equal (canonical preferred); writes flow one-way canonical→backup only; keeping backups current needs **no byte caching on the Mac** (the canonical is the byte store) — only tiny metadata (per-drive presence + pending-deletion hashes).

Concretely, 5a delivers:
1. **Clone (canonical → backup):** a re-runnable, diff-driven, hash-verified mirror copy.
2. **Backups as first-class durable drives:** tracked, browsable, valid read/verify sources, canonical preferred.
3. **Durable deletion propagation:** a deletion reaches *every* drive that holds the photo, including backups connected later — so nothing resurrects from an unplugged backup.

### Non-goals (explicit)

- **Catalog snapshot / fresh-Mac adoption** → Slice 5b.
- **Migration / role flag-flip** → Slice 5c.
- **Copying brand-new imports Mac→backup directly** (bypassing canonical). This would let a backup get *ahead* of canonical, breaking the truth model. Additions always flow *through* canonical.
- **Auto-deleting from a backup just because canonical lacks a hash.** Deletions are driven *only* by explicit `pending_deletions` (user intent) — a hash missing from canonical might be canonical drift/loss, never an implied delete.

---

## 2. Hard invariants honored

| Invariant | How |
|---|---|
| Originals never modified/moved without explicit action | Clone only *adds* to the backup (never overwrites; collisions reported). Deletion = move to the drive's bin. |
| Machine-derived → rebuildable catalog | Per-drive presence / pending-deletion tracking is catalog-only; the backup's authority is its files + `manifest.jsonl`. |
| Nothing hard-deletes | Deletions move to the drive's `.openphoto/bin/` (`origin:"propagated"`). |
| Atomic + hash-verified | Clone reuses `VerifiedCopy` (temp→fsync→re-hash→rename) + atomic `Manifest` rewrite. |
| One-way, drives passive, no merge | Clone is canonical→backup only; a deviating backup is repaired *from* canonical; backups never feed back. |

---

## 3. Components

### 3.1 Clone — `SyncEngine.planClone` + clone-tagged apply (Core)

The existing `SyncEngine.plan(sources:destinationVault:)` re-prefixes each source vault's **root basename** (`Pictures/…`), correct for Mac-vault→drive. A canonical **drive's** manifest paths are *already* in drive layout (`Pictures/rome/IMG.jpg`), so clone needs **identity path mapping** (a mirror), not re-prefixing.

Add:

```swift
extension SyncEngine {
    /// Plan a canonical→backup mirror: diff the source drive's manifest against the destination's,
    /// queueing every source file (and sidecar) missing from the destination, IDENTITY-mapped
    /// (destRelPath == source manifest path). Additive: a path present on the destination with a
    /// DIFFERENT hash is a conflict (never overwritten); same hash is skipped. No re-prefixing.
    public func planClone(source: Vault, destinationVault dest: Vault) throws -> SyncPlan
}
```

It mirrors `plan`'s body but with `destRelPath = e.path` (and the sidecar path mirrored identically — the source drive's sidecar already lives at `Pictures/rome/.openphoto/IMG.jpg.xmp`). Re-running `planClone` after the canonical gains files naturally yields just the new files as `copies` (diff-driven incremental clone).

`apply` is reused **unchanged for the copy/verify/manifest spine**, but its sync-log currently hardcodes `event: "sync"` + the Mac as counterparty. Generalize the logging only:

```swift
public func apply(_ plan: SyncPlan, destinationVault drive: Vault, volume: DriveVolume,
                  event: String = "sync", counterpartyVaultID: String? = nil,
                  progress: (@Sendable (SyncProgress) -> Void)? = nil) async -> SyncResult
```

Defaults preserve today's behavior (sync logs "sync" with `library.vaults.first` as counterparty). Clone calls `apply(plan, destinationVault: backup, volume:, event: "clone", counterpartyVaultID: canonical.descriptor.vaultID)`. `"clone"` is already a recognized §9 sync-log event — **no format-doc change**. (When `event != "sync"`, the apply logs only the destination drive's log with the given counterparty; it does not write the Mac's "sync" log, since clone is drive→drive.)

After a clone, the Mac records the backup's `vault_presence` from the backup's post-clone manifest (so the catalog knows what the backup holds) — reuse the same presence-recording path the existing drive scan/sync uses.

### 3.2 Backups as first-class durable drives (App)

Today `AppState.canonicalVaults = registeredVaults().filter { $0.role == "canonical" }` drives presence/browse/drift/deletion/evict/rehydrate/send. 5a generalizes to **durable drives**:

- `durableVaults` = `registeredVaults().filter { $0.role == "canonical" || $0.role == "backup" }` — the set used for presence refresh, drift-scan-on-connect, drive-only browse, the "backed up" badge, deletion propagation, and as candidate sources for rehydrate / send / verified-evict.
- `canonicalVault` (singular, preferred) = the `canonical`-role drive — the **read-source preference** (full-res/rehydrate/send pick a connected canonical over a backup when both hold the hash) and the drive evict messages name.
- **Verified-evict accepts any connected durable drive:** `evict` already takes `connectedCanonical: [Vault]` and `verifyOnCanonical` iterates them re-hashing — so AppState simply passes **durable** drives (canonical + backups) instead of canonical-only. A backup connected alone now satisfies a verified evict. (Method names like `verifyOnCanonical`/`connectedCanonical` keep their Core signatures; only the *set AppState passes* widens. Renames are optional polish, out of scope.)
- The Drives panel labels each drive by role ("Canonical" / "Backup").

This is mostly an app-layer widening of which drives the existing per-drive Core operations run over; the Core operations are already per-drive and role-agnostic.

### 3.3 Durable deletion propagation (Core + App)

**The Slice 3 bug:** `DeletionPropagator.propagate` clears the `pending_deletions` row after binning on *one* drive (`catalog.clearPendingDeletions(hashes:)`, line 80) — so a second/backup drive never receives it.

**The fix — `vault_presence` is the per-drive tracker.** A `pending_deletions` row must persist until **no durable drive's `vault_presence` still holds that hash**:

- New catalog method:
  ```swift
  /// Clear a pending deletion only once NO vault holds the hash in presence — i.e. it's been
  /// binned on every copy. A still-present (e.g. disconnected backup) drive keeps it pending.
  public func clearPendingDeletionsWithoutPresence(hashes: [String]) throws
  // DELETE FROM pending_deletions WHERE hash IN (…)
  //   AND NOT EXISTS (SELECT 1 FROM vault_presence vp WHERE vp.hash = pending_deletions.hash)
  ```
- `DeletionPropagator.propagate` replaces its line-80 `clearPendingDeletions(hashes: clearedHashes)` with `clearPendingDeletionsWithoutPresence(hashes: clearedHashes)`. Ordering is already correct: it removes *this* drive's presence (line 79) first, then clears only the now-orphaned hashes. Single-drive behavior is unchanged (the one drive's presence is removed → no presence remains → cleared, exactly as before). With a second drive still holding presence, the row stays pending.
- **Per-drive review already works:** `eligible(queue:localHashes:presence:)` takes one drive's presence, so reviewing drive D shows D's outstanding deletions. When backup B connects later, its presence still holds the hash → B's Review-Deletions surfaces it → propagate bins it on B and removes B's presence → if B was the last, the row finally clears.
- **App:** the Review-Deletions gate (standalone + in-sync) runs against **each connected durable drive** (today: canonical only). Connecting a backup with outstanding deletions surfaces them.

### 3.4 "Update this backup" — connect-time behind-detection (App)

When a durable drive connects, the catalog already knows whether it's behind (presence-set vs the canonical's known contents) and whether it has pending deletions. Surface an **Update** affordance in the Drives panel / on connect:

- **Canonical also connected** → "This backup is *N* photos behind and has *M* deletions pending — update?" → runs `planClone(source: canonical, destinationVault: backup)` + `apply` (additions) and the per-drive deletion review (deletions).
- **Canonical not connected** → applies the *M* pending deletions (review gate) and reports "*N* additions pending — connect the canonical to copy them." (Additions need the canonical's bytes.)

The "behind by N" count is derivable from the catalog: hashes present on the canonical (its `vault_presence` / manifest) but absent from this backup's `vault_presence`. A small pure helper computes it for display; the authoritative copy set is still the `planClone` diff at apply time.

---

## 4. Data flow & schema

- **No new catalog table.** `vault_presence` (per `vaultID`) already records which drive holds which hash — it *is* the per-drive deletion tracker. The only schema-adjacent change is the new `clearPendingDeletionsWithoutPresence` query; `pending_deletions` is unchanged. No migration.
- **`VaultRole.backup`** becomes live: clone sets a target's `vault.json` role to `backup`; the drives list includes role `backup`.
- **Clone** is manifest-driven and identity-mapped; the backup's `manifest.jsonl` + `vault_presence` are written exactly as a normal drive's are.
- **No on-disk format change** in 5a (clone writes the already-specified `manifest.jsonl`/`vault.json`; `"clone"` is an existing §9 event). The `catalog-snapshot/` artifact lands in 5b.

---

## 5. Error handling / edge cases

| Case | Behavior |
|---|---|
| Clone, insufficient space | `apply`'s existing free-space guard fails the copy *before* writing (reuses `SyncError`/the guard). |
| Clone, name collision with different bytes | Reported as a conflict, **never overwritten** (reuses `plan`/`apply` conflict path). |
| Clone interrupted | Idempotent/resumable: only verified files enter the backup manifest; re-run resumes (reuses `apply`). |
| Deletion, a holder drive is unplugged | Row stays pending (its `vault_presence` persists); applies on that drive's next connect+review. |
| Deletion, move fails on a drive | That entry stays queued for retry (reuses `propagate`'s failed-stays-queued). |
| Backup deviates from canonical (drift) | Canonical is truth → repair the backup *from* canonical via existing `DriftReconciler.restore`; never the reverse. |
| Backup holds a hash canonical lacks, no pending deletion | **Left alone** — not auto-deleted (could be canonical loss, not a deletion). |

---

## 6. Testing

**Core (unit, temp vaults + generated mock media — never `~/Pictures`):**
1. `planClone` mirrors canonical→backup identity-mapped: a file at `Pictures/rome/IMG_1.jpg` on canonical plans a copy to the *same* path on backup (not re-prefixed); `apply` copies + verifies + writes the backup manifest.
2. `planClone` is additive & diff-driven: re-running after the canonical gains a file plans only the new file; a same-path/same-hash file is skipped; a same-path/different-hash file is a conflict (not overwritten).
3. Clone tags the sync-log `"clone"` with the canonical as counterparty.
4. Durable deletion: with the photo present on two drives, propagating to drive A bins it on A, removes A's presence, and **leaves** `pending_deletions` (B still holds it); propagating to B then clears the row. (Asserts `clearPendingDeletionsWithoutPresence`.)
5. Disconnected-backup deletion: propagate to the canonical (row persists because the absent backup's presence remains) → later "connect" the backup and propagate → row clears.
6. Single-drive regression: propagating to the only holder still clears the row (unchanged Slice 3 behavior).
7. Verified-evict accepts a backup: a local original with its only connected durable copy on a `backup`-role drive evicts (re-hash verifies against the backup).
8. "Behind by N" helper: canonical has 3 hashes, backup has 1 → behind = 2 (the 2 canonical-only hashes).

**App:** build-verified (0 warnings) + manual — Drives panel labels Canonical/Backup; "Clone canonical here" makes a backup; "Update" copies additions + reviews deletions; review-deletions surfaces on a backup that was away during a delete; read prefers canonical when both connected.

---

## 7. Task decomposition (for the plan)

1. **Core — `planClone`** (identity-mapped diff) + generalize `apply` logging (`event`/`counterpartyVaultID`). Unit tests 1–3.
2. **Core — durable deletion lifecycle:** `Catalog.clearPendingDeletionsWithoutPresence` + switch `DeletionPropagator.propagate` to it. Unit tests 4–6.
3. **Core — "behind by N" pure helper** (presence-set diff). Unit test 8. *(Also covers the verified-evict-accepts-backup test 7, which is a pass-the-durable-set change exercised in Core.)*
4. **App — durable drives:** `durableVaults`/`canonicalVault`; widen presence/browse/drift/deletion/evict/rehydrate/send to durable drives with canonical-preferred read source. Build-verified.
5. **App — clone & update UI:** Drives-panel role labels, "Clone canonical here", connect-time "Update this backup" (additions + deletion review), review-deletions across durable drives. Build-verified + manual.
6. **Docs — changelog:** master-spec changelog entry for 5a (the §5.4 principle is already recorded).

No format-doc change. `SyncEngine` copy spine, `VerifiedCopy`, `Manifest`, destinations, `sends.jsonl` unchanged.
