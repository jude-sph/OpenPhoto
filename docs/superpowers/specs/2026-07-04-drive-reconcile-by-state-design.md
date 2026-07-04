# Drive sync: reconcile-by-state (mirror the canonical) — design

**Date:** 2026-07-04
**Status:** proposed (spec-first; safety-critical, on-disk-format-adjacent)

## Decisions locked (2026-07-04)

Resolving the questions this design left open:

1. **A drive is an EXACT, COMPLETE mirror of the whole library.** DESIRED is the *full* set of catalog
   placements — every folder an asset is filed in (albums-as-folders ⇒ one hash at many paths) — not a
   canonical subset. If a photo is filed in three local folders, the drive holds it in all three. The
   drive is a backup of the entire library, so "mirror the local layout exactly" is the literal goal.
2. **Drive-only (evicted) originals are part of DESIRED, not deletions.** Freeing a photo from the Mac
   but keeping it on a drive leaves a catalog placement with no local instance; that placement is still
   "in the library" and is retained. Only content *gone from the catalog entirely* is a deletion.
3. **ACTUAL: manifest for speed, disk-hash for destruction.** Plan from the drive manifest (fast), but
   NEVER relocate/remove a file without first confirming its hash on disk. Destruction is disk-verified;
   reads are manifest-fast. (The one-off `RedundantDriveFolderCleaner` already works this way.)
4. **Reconcile only against a fully-indexed catalog.** A half-scanned vault makes live content *look*
   gone and could surface false deletions; require catalog-complete before a run, with the blast-radius
   guard as the backstop.
5. **Ordering is copy → relocate → remove-stale → (review) delete**, files-before-metadata, each step
   atomic, so an interrupted run never loses content and a re-run converges.
6. **Backups reconcile against the catalog directly**, not the canonical's reconciled state — a backup
   isn't hostage to the canonical being connected.

## Problem

Drives fall out of sync in ways that never self-correct, silently accumulate duplicates, and leave
phantom folders. All of it traces to one design choice: **we sync by replaying a queue of
operations**, and operations go stale.

Observed in a real library (16,312 assets):
- A folder moved on the Mac (`Recently-Imported-from-…` → `Import Staging/…`) left, on a connected
  drive, the folder at **both** the old and new paths — 1,704 files duplicated — because the drive-side
  move failed once (silently swallowed) and additive sync then copied the new path without removing the
  old one.
- The catalog shows a **phantom "drive-only" folder** at the old path: all 1,704 of its photos still
  have local instances (0 are genuinely drive-only), so it's purely stale `vault_presence` rows the move
  never cleaned up.
- Separate folder-move ops **stick forever** ("2 changes since last connect" that never clear) because
  replaying "move X → Y" throws when Y already exists, and the op re-queues.

These are not three bugs; they're one: **an op describes a past *action*, and by the time you replay it
the world has changed, so the op can't tell whether it's already done, half-done, or conflicting.**

## Root cause

Two cooperating mechanisms:
1. **Op-replay sync.** Changes are recorded as `pending_folder_ops` (`move`/`rename`/`create`/`delete`/
   `moveFile`) and replayed per-drive on reconnect. Replay assumes the drive is in exactly the state the
   op expects; when it isn't, the op fails, silently swallows, or sticks.
2. **Additive sync.** `SyncEngine` only ever *copies* files to their catalog paths; it never removes an
   old path. So any move leaves the old copy behind on every drive.

## The design: reconcile against the canonical, by content

Stop replaying ops. To sync a drive, **compute the difference between the drive's current state and the
canonical's desired state — keyed by content hash — and make the drive match.** No op queue.

### Desired vs. actual

- **DESIRED** = the catalog's *complete* placement set: every `(hash, path)` the library says should
  exist — spanning all folders an asset is filed in, and including drive-only (evicted) originals that
  have no local instance — mapped to drive paths via the drive's basename. The catalog is ground truth
  for *what exists and where*, and the drive mirrors it exactly (Decision 1 & 2). No canonical subset,
  no drive-only extras except review-gated deletions in flight.
- **ACTUAL** = the drive's current placements: the set of `(hash, path)` actually on the drive, from its
  `manifest.jsonl` (fast) or a scan (authoritative).

### The reconcile diff (the whole thing)

For each `(hash, path)`:

- **In DESIRED, not in ACTUAL** — the drive is missing this content at this path:
  - the same `hash` exists on the drive **at another path** → it **moved** → **relocate** the drive file
    (atomic rename) to the desired path. *Auto — content preserved.*
  - otherwise → **copy** the file onto the drive from a good source (local original, else another drive),
    hash-verified. *Auto.*
- **In ACTUAL, not in DESIRED** — the drive has content at a path the catalog doesn't want:
  - the same `hash` is still desired **at another path** → this is the **stale old path of a move** →
    **remove** it. *Auto — content is safe at the new path.* **(This is what cleans up the phantoms.)**
  - otherwise → the content is **gone from the catalog entirely** → a **genuine deletion** → **review-gate
    it** (surface for confirmation; never auto-remove).

That's it. Everything — moves, renames, folder reorgs, copies, phantom cleanup — falls out of matching
by hash. There is no `move` vs `rename` vs `moveFile` op kind; there's just "this hash should be here,
not there."

### Properties

- **Idempotent + self-healing.** Run it once, ten times, or after a half-finished operation — the drive
  always converges to the catalog. A swallowed failure can't cause permanent divergence; the next
  reconcile just notices the difference and fixes it. There are no stuck ops because there are no ops.
- **Presence is derived, not maintained.** `vault_presence` becomes a *projection* of the reconciled
  state (== drive manifest == catalog desired), so the "rebuild presence then reapply pending ops"
  dance — the thing that produced the phantom rows — disappears.

## Safety (the one line we don't cross)

"Mirror the canonical exactly" would delete from a backup anything not on the canonical. For a **move**
that's correct and automatic (the photo still exists, just relocated). But for a **true deletion** — or
if the canonical is ever *wrong* (corruption, an accidental bulk delete) — blind mirroring would erase
those photos from every backup too, defeating the purpose of a backup.

So the rule is: **auto-mirror moves/relocations; keep genuine deletions behind the review gate.** A file
whose content still exists somewhere in the catalog is safe to relocate/remove-stale automatically. A
file whose content is *gone from the catalog* is a deletion and is surfaced for review before any backup
removes it. Optionally add a blast-radius guard (if a reconcile would delete more than N% of a drive,
require explicit confirmation) so a catalog accident can't quietly wipe a drive.

Existing invariants preserved: originals never modified; all writes atomic + hash-verified; sync stays
one-way (catalog → drive), drives passive. The only refinement is distinguishing **moved** (auto) from
**deleted** (review) — which is exactly the distinction the op model failed to make.

## What it replaces

- `pending_folder_ops` (the move/rename/create/delete/moveFile queue) — **removed**. Structural changes
  are inferred from the hash diff.
- The reconnect review's op list — **replaced** by a reconcile plan: *N to copy, N to relocate (auto),
  N stale-old-paths to remove (auto), N deletions (review)*.
- `SyncEngine`'s additive-only copy — **replaced** by reconcile, which copies, relocates, and removes.

## Cleaning up the existing mess (for free)

Running reconcile against today's messy drives:
- The phantom old-path files (`Recently-…apple-photos-mac`) — hash present at the new path → recognized
  as **moved** → old path + stale presence **removed automatically**.
- The sky/apple-photos duplicates — old-path copies removed as move-sources; new-path kept.

So the redesign **self-heals** the current duplication and phantoms; no separate migration tool needed.
(The interim `merge folders` feature remains useful only for genuinely-distinct local folders you *chose*
to combine, not for these artifacts.)

## Phasing

1. **Reconcile core (pure + dry-run).** `computeReconcilePlan(desired, actual) -> ReconcilePlan`
   (copies, relocations, stale-removals, review-deletions). Pure function over two sets → fully
   TDD-able. Ship as a read-only "what would reconcile do?" first.
2. **Execute.** Wire the plan into the reconnect/sync UI: auto-apply copies + relocations +
   stale-removals off-main with progress; list genuine deletions for review. Replaces op-replay.
3. **Retire.** Remove `pending_folder_ops` and the additive `SyncEngine` copy path once reconcile owns
   sync. Update `docs/format/` (sync semantics + the dropped ops table) in the same commit.

## Testing

The diff is a pure function over `(desired: Set<Placement>, actual: Set<Placement>)`, so every case is a
table test:
- move → relocate + remove-old (no copy, no delete);
- new content → copy;
- genuine deletion → review (never auto-removed);
- phantom (hash at old path, desired only at new path) → stale-removal;
- idempotence (reconcile of an already-matching drive → empty plan);
- blast-radius guard trips at the threshold.
Execution reuses the already-tested atomic move/copy/verify primitives.

## Open questions

All resolved — see **Decisions locked (2026-07-04)** at the top:
- ACTUAL from manifest vs. scan → Decision 3 (manifest to plan, disk-hash before any destruction).
- Multi-vault / multi-placement DESIRED → Decisions 1 & 2 (exact complete mirror, incl. evicted originals).
- Backups vs. canonical → Decision 6 (backups reconcile against the catalog directly).

Remaining to settle during planning (not blockers):
- **Copy-source selection** when the drive is missing content: local original first, else another
  connected drive; how to behave when the only source is an offline backup (defer that placement).
- **Reconcile cadence & short-circuit.** Off-main on reconnect; skip the diff entirely when the drive
  manifest is unchanged since last reconcile (store a manifest digest per drive).
