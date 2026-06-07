# OpenPhoto

Native macOS photo manager. The library is just files — the app indexes, views, imports, and syncs, but the library remains fully usable with the app deleted.

## Key documents

- `docs/superpowers/specs/2026-06-07-openphoto-design.md` — approved architecture design (vault + catalog, sync flows, intelligence, phases)
- `docs/format/vault-format-v1.md` — **normative on-disk format spec**, written for third-party implementors
- `docs/SPECS.md` — original raw requirements
- `docs/claude-design-prompt.md` — UI mockup prompt for Claude Design

## Hard invariants (never violate)

1. Original media files are never modified or moved without explicit user action.
2. Human-authored metadata → XMP sidecars; machine-derived data → rebuildable catalog only.
3. Nothing hard-deletes; deletion = move to a bin.
4. All writes atomic (temp → fsync → rename); all copies hash-verified.
5. Sync flows are strictly one-way; drives are passive; no merge logic exists.

## Documentation discipline

**Sovereignty depends on documentation.** Any change to the on-disk format (vault layout, manifest/JSON schemas, sidecar conventions, catalog snapshot) MUST update `docs/format/` in the same commit. Future external software (e.g. server photo-cloud reading a canonical drive) implements against those docs, not against this codebase. When the catalog schema stabilizes, document it in `docs/format/catalog-schema.md`. Significant architecture decisions get recorded by revising the design spec (with a dated changelog entry) rather than leaving the doc stale.
