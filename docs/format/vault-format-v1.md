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
    imports.jsonl                  ← device-import registry (§12)
    sends.jsonl                    ← confirmed-send registry (§13)
    devices.jsonl                  ← known-device registry (§14)
    staging/                       ← transient import workspace — readers MUST ignore
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
- When OpenPhoto syncs a Mac library onto a canonical drive it acts as a third-party writer per §10: each source vault maps to a top-level directory named by that root's basename, originals are added but never overwritten (a name collision with differing bytes is reported, not replaced), and `manifest.jsonl` is rewritten atomically after each sync. No fields beyond those specified in this document are used.

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
| Favorite | `xmp:Label` with value `"Favorite"` |
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

A *vault's* propagated deletions therefore land in that vault's own `.openphoto/bin/` (the same mechanism as a local deletion), tagged `origin:"propagated"`. The volume-root `.openphoto-trash/` directory of §12 is used **only** for deletions on removable *non-vault* volumes (e.g. an SD card during import), which have no `.openphoto/` vault to host a bin.

## 9. `sync-log.jsonl` (informative)

Append-only journal of import/sync/clone/evict sessions, one JSON object per line with at minimum `{"event", "at", "counterparty_vault_id", "summary"}`. Event names include `"import"`, `"device-delete"`, `"send"`, `"sync"`, `"clone"`, `"evict"`, `"rehydrate"` (an evicted original copied back from a drive), `"delete"` (a reviewed deletion propagated to this vault's bin). Diagnostic and forensic value; readers MUST NOT require it. For purely local events that have no other party (e.g. `"evict"`), `counterparty_vault_id` is the empty string `""`.

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

## 12. Import registry (`imports.jsonl`)

Durable record of every item OpenPhoto has imported from an external device
(phone, SD card). One JSON object per line:

```json
{"hash":"sha256:…","imported_at":"2026-06-08T02:10:00.000Z","imported_to":"rome2026/IMG_6385.HEIC","name":"IMG_6385.HEIC","size":2888127,"source_key":"jude-iphone-ABC123","taken_at":"2026-06-08T01:15:58.000Z"}
```

- `source_key` — stable device identity (device name + serial, or volume UUID).
- Lookup key is `(source_key, name, size, taken_at)`; `hash` records what the
  bytes were. Entries are never removed: "imported once" is permanent memory,
  surviving renames, evictions, and deletion from the library.
- Lives in the **primary** vault's `.openphoto/` (the first configured root).
- `.openphoto/staging/` is a transient import workspace; readers MUST ignore
  it. OpenPhoto clears it at session start.
- On removable volumes OpenPhoto deletes by moving files into
  `.openphoto-trash/` at the volume root — never unlinking (§8 spirit).

## 13. Send registry (`sends.jsonl`)

Durable record of every asset OpenPhoto has **confirmed** sending to a device
(phone via AirDrop, or a mounted volume via copy). One JSON object per line:

```json
{"confirmed_at":"2026-06-08T13:31:12.000Z","destination_key":"vol-ABC123","device_kind":"volume","device_name":"Backup SSD","fp_capture_date_ms":1434378600000,"fp_size":31853,"hash":"sha256:…","sent_at":"2026-06-08T13:30:00.000Z"}
```

- `hash` — the library asset's content hash (`sha256:` …).
- `destination_key` — stable device identity (phone serial / volume UUID); same keyspace as `imports.jsonl`'s `source_key`.
- `device_kind` — `"phone"` | `"volume"`.
- `fp_size` / `fp_capture_date_ms` — the size + capture date (epoch ms) used as a cheap "is it still there?" fingerprint on re-connect. **Filename is deliberately not recorded** — Apple Photos rewrites it when a photo is saved.
- Lookup key is `(destination_key, hash)`; entries are append-only and never pruned. Only confirmed sends are recorded (an AirDrop with no verified landing writes nothing).
- Lives in the **primary** vault's `.openphoto/`.

## 14. Device registry (`devices.jsonl`)

Known devices OpenPhoto has seen, for friendly names in the UI. One JSON object per line:

```json
{"first_seen":"2026-06-08T10:00:00.000Z","key":"vol-ABC123","kind":"volume","last_seen":"2026-06-09T18:22:00.000Z","name":"Backup SSD"}
```

- `key` — stable device identity (same keyspace as above). `kind` — `"phone"` | `"volume"`.
- `name` and `last_seen` update on each connect; `first_seen` is preserved. Informative; readers MUST NOT require it.
- Lives in the **primary** vault's `.openphoto/`.
