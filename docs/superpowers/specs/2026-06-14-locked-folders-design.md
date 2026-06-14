# Locked folders (Touch ID) — Design

**Date:** 2026-06-14
**Status:** Approved (app-level lock; casual-snooping threat model).

## Problem

Let the user hide certain folders behind Touch ID inside OpenPhoto — like Apple Photos' Hidden
album. Locked folders' photos disappear from every browse surface until the user authenticates
(Touch ID, falling back to the Mac password); then they reappear for the session.

**Scope is explicitly app-level.** The files stay plaintext on disk (still visible in Finder/Preview).
This deters casual snooping in OpenPhoto; it is **not** encryption-at-rest. (Real encryption was the
rejected stronger option — it would break OpenPhoto's "your library is just plain files" promise for
that subset.)

## Approach

A folder is locked by its path. A per-**instance** `locked` flag (folders are instance locations in
the catalog) is derived from the locked-folder list. A single in-memory `revealLocked` switch on the
catalog gates whether the user-facing browse queries filter locked rows out. Touch ID flips it on for
the session; "Lock now" / quitting flips it off. The locked-folder list is the source of truth; the
`locked` flag is rebuildable from it (re-derived on library open), consistent with "catalog is
derived, rebuildable."

This mirrors the reversible-hide flag already shipped for faces — a flag + a conditional filter — but
applied library-wide across the browse surfaces.

## Components

| Unit | Responsibility |
|---|---|
| Catalog migration **v16** | `ALTER TABLE instances ADD COLUMN locked INTEGER NOT NULL DEFAULT 0`. |
| `Catalog.applyLockedFolders(_ dirPaths:)` | Re-derive `instances.locked`: reset all to 0, then set 1 where `dirPath` equals or is nested under (`GLOB "<dir>/*"`) any locked folder. Same path-match the folder view uses. |
| `Catalog.revealLocked` (in-memory `var`, default `false`) | When `false`, the user-facing browse methods add `AND locked = 0`; when `true`, they don't. Set by the App on unlock/lock. Never persisted (re-locks on quit naturally). |
| Browse query filtering | `browseSQL` / `instanceSQL` projections carry the `locked` column; each **user-facing** browse method wraps them and appends the locked filter when `!revealLocked`. See "Surfaces" — every one must be covered or locked photos leak. |
| `LockedFolders` (App config) | The list of locked relative folder paths, persisted at `<library>/.openphoto/locked-folders.json` (survives catalog rebuild; travels with the library). Load on open → `applyLockedFolders`. |
| `BiometricGate` (App) | `LocalAuthentication` wrapper: `authenticate(reason:) async -> Bool` via `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` (Touch ID, automatic password fallback; works on Macs without Touch ID and in our ad-hoc-signed bundle — no entitlement/usage-string needed). |
| `AppState` (lock state + actions) | `lockedRevealed: Bool` (false at launch); `lockFolder(dirPath:)` / `unlockFolder(dirPath:)` (edit list → persist → `applyLockedFolders` → refresh); `revealLocked()` (Touch ID → set `catalog.revealLocked = true` → refresh all browse) / `relock()`; `isFolderLocked(dirPath:)`. |
| Folders UI | Context menu **Lock (Touch ID)** / **Unlock** on a folder; a 🔒 badge on locked folders in the tree. Entering a locked folder while not revealed prompts Touch ID. |
| Sidebar UI | A lock/unlock control: 🔒 when locked content is hidden → tap → Touch ID → reveal; 🔓 + **Lock now** when revealed. |

## Surfaces that MUST filter locked rows (when `!revealLocked`)

Audited from `Catalog/Queries.swift`, `Catalog+Geocode.swift`, `Catalog+Faces.swift`, search:

- **Timeline** — `timelineItems(videoOnly:)` (and the `browseSQL`-based section/count paths feeding `AppState.sections`/`flatItems`).
- **Folders** — `items(inDir:vaultID:recursive:)`, `folderCounts(...)`, and the folder tree (locked folders show badged, but their *contents* gate).
- **Open by id** — `items(instanceIDs:)`, `item(hash:)` (so a locked item can't be resolved into the viewer while hidden).
- **Map** — the geocoded-coordinates query (`Catalog+Geocode`).
- **People / faces** — `unassignedAutoFaceIDs`, `unassignedFacesWithEmbeddings`, `people()` cover faces, `faces(forPerson:)` — a face from a locked photo must not appear in People/suggestions while hidden. (Filter via the face's `hash` → its instance(s) `locked`.)
- **Search** — semantic search results + `searchOCR` + filter search.
- **Tidy-up / dedup** — `duplicateInstanceGroups(scope:)`, near-dup/cull groups.
- **Counts** — user-facing `librarySize()` / sidebar counts reflect the revealed set.

## Surfaces that MUST NOT filter (internal — locked photos still participate)

- **Derivation** — `pendingDerivation(...)`: locked photos are still analysed (faces/embeddings/etc.) so they're ready when unlocked. Just hidden from browse.
- **Import dedup** — `knownSizeDateKeys()`: still match locked photos so a locked photo isn't re-imported.
- **Integrity / scan / sync** — all-hash sets, `instances`, manifest reconciliation, drift, eviction: operate on the full set regardless of lock.

> Implementation note: because `browseSQL`/`instanceSQL` are shared by both user-facing and internal
> callers, the locked filter is applied in the **outer** query of each user-facing method (not baked
> into the shared projection), so internal callers are unaffected. The shared projections must expose
> the `locked` column for the outer `WHERE` to reference.

## Session / UX model

- Launch → `lockedRevealed = false`, `catalog.revealLocked = false`. Locked photos hidden everywhere.
- Reveal: any "unlock" affordance → `BiometricGate.authenticate` → on success set both flags true + refresh every browse surface. Locked content now appears (optionally with a subtle 🔓 indicator).
- Re-lock: a manual **Lock now**, and implicitly on app quit (in-memory flag resets). (Auto-relock on app-backgrounded is a possible later refinement; not in v1.)
- Locking a folder: context menu → (no Touch ID needed to *add* a lock) → persist + derive flags + refresh; the folder's photos vanish from the revealed surfaces if currently locked. Unlocking a folder (removing it from the list) requires the session to be revealed (you must be authenticated to manage locks).

## Out of scope

- Encryption at rest / protecting the files from Finder (the rejected stronger option).
- Per-photo locking (folder-grain only in v1).
- Auto-relock on backgrounding / idle timeout.
- Locking faces/people directly (faces inherit their photo's lock).

## Honest limitation (restated, for the implementer & any docs)

Files remain plaintext on disk. This is privacy-from-snooping within OpenPhoto, not security against
someone with file access. The lock list itself (`locked-folders.json`) is readable and names the
locked folders — acceptable under the casual-snooping threat model.
