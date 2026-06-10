# Phase 3 Slice 5c — Canonical Management & Migration (design)

**Date:** 2026-06-10
**Branch:** `phase3-drives`
**Status:** Approved
**Builds on:** 5a (clone, `durableVaults`/`canonicalVault`, `cloneToBackup`, `backupBehindCount`, per-drive deletion durability), 5b (`Vault.writingRole(.canonical/.backup)`, role self-description in `vault.json`, confirmed adoption). Reuses the Mac→canonical `SyncEngine` and `forgetDrive`.

> **The LAST required Phase 3 slice.** After it: merge `phase3-drives` → `main`. (Slice 5d Quick View is optional/after.)

---

## 1. Goal

Give the user explicit control over **which drive is the canonical** (the single source of truth), safely:
- **Change** the canonical (promote a backup, demote the old) — gated on the backup being an *exact* copy.
- **Recover** when the canonical is lost/failed — promote a backup as the new canonical, acknowledging any data loss and salvaging everything the Mac still holds.
- **Migrate** to a new/bigger drive — purely by composing existing mechanisms (add → clone → promote).

The principle from 5a stands: **canonical is truth, backups are derived, flows are one-way, no merge logic.** 5c adds the role *lifecycle*; the copy/role/presence machinery already exists.

### Non-goals (deferred)
- **Migrating the canonical onto the Mac itself** (master-spec §5.5's "drive or the Mac"). The Mac is role `local` — a different model; deferred, noted in §5.5.
- **Multi-drive consensus repair in Verify Integrity** → Phase 5 backlog (it's a drift/integrity-layer enhancement, not role management).

---

## 2. Hard invariants honored

| Invariant | How |
|---|---|
| Exactly one canonical | The **catalog** role is authoritative; the promote/demote role flip is a **single atomic transaction** (`Catalog.setCanonical`). `vault.json` is the drive's self-description, reconciled to the catalog on reconnect. |
| One-way, no merge | Promotion is a role-metadata flip (no content move). Recovery salvage is the **existing Mac→canonical one-way sync** (additive, hash-verified) — never a drive-to-drive merge. |
| Originals never touched | Only `vault.json` role bytes are rewritten (atomic, via `writingRole`); media files are untouched. |
| Agreement = exact, no resurrection/loss | A backup is promotable only when its content set **exactly equals** the canonical's; re-verified against both manifests at promotion time. |

---

## 3. The promotability gate — exact agreement

A backup is **promotable** iff its live content set is *exactly equal* to the canonical's — same hashes, nothing missing, nothing extra. (Extra = an un-applied deletion the backup still holds; promoting it would resurrect a deleted photo. Missing = behind on additions; promoting it would lose them.) The fix for either is **"Update backup"** (5a — clones additions + applies pending deletions) until equal.

- **Pure Core helper** (unit-testable): `canonicalAgreement(canonicalHashes: Set<String>, backupHashes: Set<String>) -> Bool` ≡ set equality.
- **UI gate** (`AppState.isPromotable`): the backup is connected, the canonical is connected, and their **catalog presence sets** (`vaultPresenceHashes`) are equal — cheap, drives the button's enabled state.
- **Promotion-time verification:** before flipping, re-read **both manifests** (the authoritative inventory) and confirm exact equality. If they differ (the catalog cache was stale, or drift occurred), abort with *"This backup is no longer an exact copy of the canonical — run Update backup first."* No merge, ever.

---

## 4. Planned promotion — "Make this the canonical"

On a **backup** drive in the Drives panel: **"Make this the canonical."**

- **Canonical connected + backup promotable** → enabled. On confirm: re-verify via manifests (§3), then flip:
  - `Catalog.setCanonical(newID:, demoting: oldID:)` — a **single transaction** setting the new drive's role `canonical` and the old's `backup`, so the catalog never has zero or two canonicals.
  - Then rewrite `vault.json` best-effort: `writingRole(.canonical)` on the new, `writingRole(.backup)` on the old. If a `vault.json` write fails (e.g. a drive drops mid-op), the **catalog is already correct** (authoritative); the stale `vault.json` is reconciled by the conflict detector (§6) on reconnect.
- **Canonical NOT connected** → the action **guides the user to plug it in** rather than silently disabling: *"Plug in your current canonical ('X') so OpenPhoto can confirm this backup is a complete, current copy before switching — or, if your canonical is lost, recover from this backup instead → Recover."* So the normal path nudges connecting the canonical (to compare the drives); **recovery (§5) is the explicit "it's gone" exception.**

Promotion moves no media and writes no snapshot (roles don't change contents; the snapshot's portability key already says readers ignore `vaults.role`).

---

## 5. Recovery promotion — "My canonical died"

When the canonical is **not connected** (lost/failed), a backup offers a **confirmed, acknowledged** "Make this the new canonical." It cannot verify agreement against the absent drive, so it is honest about the risk and salvages everything still reachable:

1. **Acknowledge precisely** (when the lost canonical is still *registered* — i.e. died but not yet forgotten — the catalog still holds its last-known presence): compute
   - `atRisk = lostCanonicalHashes − backupHashes` (on the dead canonical, not on this backup),
   - `recoverableFromMac = atRisk ∩ macLocalHashes` (the Mac still has the originals),
   - `lost = atRisk − macLocalHashes` (nowhere reachable),
   and prompt: *"Recovering from 'Backup' (N photos). Your lost canonical last held M; K of those aren't on this backup. J will be copied from this Mac onto the new canonical; L exist nowhere reachable and will be lost. Continue?"* If the lost canonical was already forgotten (no presence), show a generic acknowledgment instead. *(Pure Core helper `recoveryLoss(lostCanonicalHashes:backupHashes:macLocalHashes:) -> RecoveryLoss` — unit-testable.)*
2. **Flip:** `Catalog.setCanonical(newID:, demoting: lostID?)` (the lost drive's catalog role → backup even though it's absent), then `writingRole(.canonical)` on the new (present); the lost drive's `vault.json` is reconciled later on reconnect (§6).
3. **Salvage from the Mac — via the existing one-way sync:** run **Mac → new-canonical** `SyncEngine` plan+apply. The Mac pushes every local original the new canonical lacks (additive, hash-verified). This recovers the `recoverableFromMac` set (and anything else local).
4. **Report:** *"Recovered J from this Mac; L could not be recovered (only existed on the lost drive)."*

Truly lost = photos evicted from the Mac **and** never cloned to this backup — genuinely gone, and the program says so.

---

## 6. The reappearing old canonical (conflict resolution)

The catalog's registered canonical is the single source of truth. A **connected** durable drive whose `vault.json` role is `canonical` but which is **not** the registered canonical is a conflict — left over from a recovery (the old drive turning up) or a partial flip whose `vault.json` write didn't land.

- **Detector** (`AppState.conflictingCanonical`): a connected drive `vr` where the opened vault's `descriptor.role == .canonical` **and** `vr.id != canonicalVault?.id`.
- **Resolve (confirmed, never silent):** prompt *"'Old' was your previous canonical; 'New' is canonical now. Make 'Old' a backup (it'll need updating), or Forget it?"*
  - **Make a backup** → `Catalog.setCanonical` already has it as `backup`; rewrite its `vault.json` via `writingRole(.backup)` to reconcile. It then shows as a behind backup to **Update**.
  - **Forget** → `forgetDrive` (unregisters + clears its presence).

This also runs when *adding* such a drive (`addDriveViaPanel` already reads `vault.json` role; if it claims canonical while one exists, route to the same resolution). Guarantees exactly-one-canonical converges.

---

## 7. Migration = composition (no new copy engine)

Migrate to a new/bigger drive by composing what exists:
1. **Add** the new drive (5b add flow).
2. **Clone/Update** canonical → it (5a `cloneToBackup` / "Update backup", both connected, hash-verified) until it's an **exact** copy.
3. **Promote** it (§4) — it becomes the canonical; the old **demotes to backup** (kept as redundancy by default).
4. Optionally **Forget** the old to retire it.

So 5c ships the flip + gate + recovery + conflict UI; nothing copies media that didn't already.

---

## 8. Components (new)

**Core (TDD):**
- `canonicalAgreement(canonicalHashes:backupHashes:) -> Bool` — exact set equality.
- `struct RecoveryLoss { recoverableFromMac: Int; lost: Int }` + `recoveryLoss(lostCanonicalHashes:backupHashes:macLocalHashes:) -> RecoveryLoss`.
- `Catalog.setCanonical(_ newID: String, demoting oldID: String?) throws` — one transaction: `UPDATE vaults SET role='canonical' WHERE id=new`; `… 'backup' WHERE id=old` (if non-nil).

**App (build-verified + manual):**
- `isPromotable(_ vr:) -> Bool` (gate); `promoteToCanonical(_ vr:) async -> Bool` (manifest re-verify → `setCanonical` → best-effort `writingRole` → refresh).
- `recoveryAcknowledgment(_ vr:) -> RecoveryLoss?` (nil if the lost canonical's contents are unknown); `recoverCanonical(_ vr:) async` (flip → Mac→canonical salvage sync → refresh + report).
- `conflictingCanonical: VaultRecord?` + `resolveCanonicalConflict(_ vr:, makeBackup: Bool)`.
- Drives-panel affordances: "Make this the canonical" (enabled when promotable + canonical connected; the guided plug-in prompt otherwise), "Make this the new canonical" (recovery, canonical absent, acknowledged), and the conflict prompt; reuse the existing `forgetDrive`/`cloneToBackup` actions for migration.

No new on-disk artifact; **no catalog migration** (roles already exist).

---

## 9. Error handling / edge cases

| Case | Behavior |
|---|---|
| Crash/disconnect between the catalog flip and a `vault.json` write | The catalog (authoritative) is already correct; the stale `vault.json` is reconciled by the conflict detector on reconnect. |
| Backup no longer exactly equal at promotion (stale cache / drift) | Manifest re-verify fails → abort, "run Update backup first." No partial flip. |
| Canonical disconnects mid-promotion | The action requires both connected; if it drops before the flip, abort (nothing changed). |
| Recovery with the lost canonical already forgotten | No precise diff (its presence was cleared) → generic acknowledgment; the Mac-salvage sync still recovers everything local. |
| Old canonical reappears after recovery | Conflict detector → confirmed demote-to-backup (reconcile `vault.json`) or forget. Never two canonicals. |
| Two registered canonicals somehow exist | `canonicalVault` picks one; the other (a connected drive whose role==canonical but ≠ that one) is surfaced by the conflict detector for resolution. |
| Promote the drive that's already canonical / no canonical exists | "Make canonical" is offered only on a `backup` while a different canonical exists; recovery only when the canonical is absent. |

---

## 10. Testing

**Core (unit, temp vaults + generated media — never `~/Pictures`):**
1. `canonicalAgreement`: equal sets → true; backup missing one → false; backup with an extra → false.
2. `recoveryLoss`: lost={a,b,c}, backup={a}, macLocal={b} → recoverableFromMac=1 (b), lost=1 (c).
3. `Catalog.setCanonical`: flips new→canonical + old→backup atomically; with `demoting: nil` only promotes; the registered canonical set has exactly one member afterward.
4. Promote mechanics (Core/integration): two drives (a `canonical` + an exactly-equal `backup`), after `setCanonical` + `writingRole` the catalog roles and both `vault.json`s read canonical/backup swapped; a *behind* backup fails the agreement gate.

**App:** build-verified (0 warnings) + manual — "Make this the canonical" enabled only when the backup is an exact copy and the canonical is connected; the plug-in-the-canonical guidance when it isn't; recovery offered + acknowledged when the canonical is absent, with the salvage sync; reconnect the old canonical → conflict prompt; migration = add + clone + promote.

---

## 11. Task decomposition (for the plan)

1. **Core** — `canonicalAgreement` + `recoveryLoss` (+ `RecoveryLoss`). TDD (tests 1–2).
2. **Core** — `Catalog.setCanonical(_:demoting:)`. TDD (test 3).
3. **App** — `isPromotable` + `promoteToCanonical` (manifest re-verify → atomic flip → best-effort `vault.json` → refresh). Build-verified; the flip mechanics covered by a Core/integration test (test 4).
4. **App** — `recoveryAcknowledgment` + `recoverCanonical` (acknowledged flip → Mac→canonical salvage sync → report). Build-verified.
5. **App** — `conflictingCanonical` detector + `resolveCanonicalConflict` + the Drives-panel UI for promote / recovery / conflict + guided plug-in prompt. Build-verified + manual.
6. **Docs** — master-spec §5.5 (canonical management & migration; Mac-target deferred) + changelog. Then **finish the branch** (merge `phase3-drives` → `main`).
