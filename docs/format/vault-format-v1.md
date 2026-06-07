# OpenPhoto Vault Format — Version 1

**Status:** DRAFT — becomes normative when Phase 1 ships. Field names may be refined during implementation; **any code change to the on-disk format MUST update this document in the same commit.**

**Audience:** anyone implementing software that reads or writes an OpenPhoto library *without* OpenPhoto — e.g. server-based photo cloud software reading a canonical drive, migration tools, backup verifiers. After reading this document you should be able to fully interpret a vault with no other information.

**Design contract:** a vault is self-describing and tool-independent. Originals are never modified by any conforming software. Everything human-meaningful is in plain files (JSONL, XMP); binary databases are caches that may be ignored or deleted.

---

## 1. Vault layout

A **vault** is a folder tree containing media files, organized however the user likes (arbitrary names, arbitrary nesting). App state lives only in `.openphoto/` directories.

```
<vault-root>/
  .openphoto/                      ← vault-level state (only at the root)
    vault.json                     ← identity & format version
    manifest.jsonl                 ← authoritative inventory (hash ⇄ path)
    sync-log.jsonl                 ← append-only event journal (informative)
    bin.jsonl                      ← deletion records
    bin/                           ← deleted files, original relative paths preserved
    catalog-snapshot/              ← OPTIONAL binary cache (see §7) — safe to ignore/delete
  rome2022/
    IMG_4123.heic
    IMG_4123.mov                   ← Live Photo pair of the HEIC (see §6)
    .openphoto/                    ← folder-level state: XMP sidecars ONLY
      IMG_4123.heic.xmp
  anything/nested/anyhow/…
```

Rules:

- A directory named `.openphoto` is never media content. Scanners must skip it when enumerating photos.
- The vault-root `.openphoto/` holds vault state. Folder-level `.openphoto/` directories hold **only** XMP sidecars for that folder's files.
- A Mac library typically consists of two vaults (`~/Pictures`, `~/Movies`). A drive carries **one** vault whose top-level directories mirror the source vault roots by name (`Pictures/`, `Movies/`).

## 2. Asset identity

The identity of an asset is the **SHA-256 hash of its file bytes**, serialized as `sha256:` + 64 lowercase hex chars. The algorithm prefix is mandatory; readers MUST treat unknown prefixes as unknown-but-distinct identities, allowing future algorithm migration. (v1 ships SHA-256 — hardware-accelerated on Apple Silicon and dependency-free; BLAKE3 remains a possible future prefix.)

```
sha256:9f42ab…c81d
```

Consequences any implementation can rely on:

- Renames/moves never change identity. Identity is location-independent.
- Two files with equal hashes are the same asset (duplicate instances).
- Originals are immutable by contract, so identity is permanent. A changed file is a *different asset*, not a new version of the old one.

## 3. `vault.json`

```json
{
  "format_version": 1,
  "vault_id": "0f9b2a4e-7c31-4e8d-9a52-1b6f0e3d8c77",
  "role": "local",
  "created_at": "2026-06-07T19:42:11.000Z",
  "app": "OpenPhoto/0.1"
}
```

- `format_version` — integer. Readers MUST refuse formats newer than they understand.
- `vault_id` — UUID, stable for the vault's lifetime. Used to key presence maps.
- `role` — `"local"` | `"canonical"` | `"backup"`. Advisory designation; the user's catalog is the arbiter.
- `app` — last writer, informative only.

## 4. `manifest.jsonl`

The authoritative inventory: **one JSON object per line, one line per media file currently in the vault** (bin contents are not listed; see §8). Encoding UTF-8, LF line endings.

```json
{"hash":"sha256:9f42…","path":"rome2022/IMG_4123.heic","size":4123456,"mtime":"2022-10-07T14:23:01.512Z"}
```

- `path` — vault-root-relative, `/` separators, NFC-normalized Unicode.
- `size` — bytes.
- `mtime` — file modification time, ISO-8601 UTC with millisecond precision. Used with `size` as a fast-path to skip re-hashing during reconciliation; the hash is always the truth.
- Sidecars, `.openphoto` contents, and non-media files are not listed.

Writers MUST rewrite the manifest atomically (temp file → fsync → rename). The manifest is reconstructible by walking the tree and hashing — it is authoritative as an *inventory claim* to diff against, not an irreplaceable record.

**Reconciliation rule:** when filesystem and manifest disagree, the filesystem wins for existence; the manifest's hashes win for identity claims pending re-hash. OpenPhoto surfaces disagreements on passive vaults (drives) as "drift" for human review.

## 5. Sidecars (XMP)

Human-authored metadata lives in per-file XMP sidecars, in the folder-level `.openphoto/` directory, named by **appending `.xmp` to the complete filename**:

```
rome2022/IMG_4123.heic  →  rome2022/.openphoto/IMG_4123.heic.xmp
```

Standard namespaces, chosen for maximal third-party intelligibility:

| Data | XMP property |
|---|---|
| Rating (0–5) | `xmp:Rating` |
| Tags (flat) | `dc:subject` |
| Tags (hierarchical, optional) | `lr:hierarchicalSubject` |
| Caption | `dc:description` |
| Title | `dc:title` |
| People / face regions | MWG Regions (`mwg-rs:Regions`), `Type="Face"`, with `Name` |

Notes:

- A sidecar exists only if there is something to record. Absence of a sidecar = no human-authored metadata.
- Sidecar association is by filename. After an outside rename, OpenPhoto self-heals the association via content hash; third-party writers renaming media SHOULD rename the sidecar in the same operation.
- Only *human-confirmed* people appear in sidecars. Machine guesses (unconfirmed clusters) never leave the catalog.

## 6. Live Photos

A Live Photo is one logical asset made of two files (e.g. `IMG_4123.heic` + `IMG_4123.mov`), each with its own hash and manifest line. Pairing is determined by Apple's content identifier (`com.apple.quicktime.content.identifier` in the MOV; the corresponding Maker Apple key in the HEIC). Fallback heuristic when stripped: same basename in the same folder with capture timestamps within 2 seconds. Sidecar metadata attaches to the still image's sidecar; the video carries none.

## 7. `catalog-snapshot/` (optional, non-normative)

A copy of the OpenPhoto catalog (SQLite) and thumbnail cache, refreshed by the Mac at the end of each sync. It exists so a fresh machine gets search/faces/thumbnails without re-running ML.

Third parties: **treat it as a disposable accelerator.** The authoritative data is always files + sidecars + manifest. You may read it (schema documented in `catalog-schema.md` once stable), but MUST NOT treat it as a source of truth and MUST NOT write to it. OpenPhoto regenerates it wholesale.

## 8. Deletion (`bin/`, `bin.jsonl`)

Conforming software never hard-deletes. Deletion = move the file (and its sidecar) into `<vault-root>/.openphoto/bin/<original relative path>`, remove its manifest line, and append a record to `bin.jsonl`:

```json
{"hash":"sha256:9f42…","path":"rome2022/IMG_4123.heic","deleted_at":"2026-06-07T20:01:00.000Z","origin":"propagated"}
```

`origin` is `"user"` (deleted directly in this vault's UI) or `"propagated"` (a reviewed deletion synced from the user's catalog). Restore = the reverse move + manifest line re-added.

## 9. `sync-log.jsonl` (informative)

Append-only journal of import/sync/clone/evict sessions, one JSON object per line with at minimum `{"event", "at", "counterparty_vault_id", "summary"}`. Diagnostic and forensic value; readers MUST NOT require it.

## 10. Rules for third-party writers

If your software (e.g. a photo server ingesting a plugged-in canonical drive) wants to *write* to a vault rather than just read it:

1. **Never modify or overwrite an existing media file.** Ever. New content = new file.
2. Write atomically: temp file in the same filesystem → fsync → rename.
3. Adding a file: place it, then add its manifest line (atomic rewrite).
4. Renaming/moving: rename media + sidecar together, update the manifest.
5. Deleting: follow §8. Never `unlink`.
6. Leave `catalog-snapshot/` alone; OpenPhoto rebuilds it.
7. If you can't update the manifest, your additions will still be discovered — OpenPhoto reconciles the filesystem against the manifest on every mount and surfaces differences as drift for the user to adopt. Updating the manifest just makes that frictionless.

## 11. Versioning policy

- Backwards-compatible additions (new optional JSON fields, new informative files) do not bump `format_version`.
- Any change that alters the meaning of existing data bumps `format_version`; OpenPhoto will read all older versions and migrate forward only with user consent.
- This document is the single source of truth for the format. The implementation defers to it; divergence is a bug.
