# OpenPhoto — Code Audit

_Read-only audit. Generated 2026-06-13 by a multi-agent workflow (1 architecture mapper + 34 dual-lens subsystem auditors covering every Swift file twice, with adversarial verification of every Critical/High finding + a themes synthesizer + a completeness critic — 70 agents total). No source files were modified; this report is the only artefact._

**Findings after verification & dedup: 189** — 1 Critical · 12 High · 95 Medium · 81 Low. Every Critical/High was re-checked by an independent skeptic; 3 flagged issues were refuted (see appendix) and 17 inflated Highs were downgraded.

**How to read this:** the triage table is the index; detailed entries follow, grouped by severity. `Confidence` reflects the verifier's verdict where one ran. Suggested fixes are sketches — none have been applied.

---

## Architecture overview

OpenPhoto is a two-target Swift 6 / SwiftUI app on macOS 15+, defined in `Package.swift`. **`OpenPhotoCore`** is a platform library holding all domain logic — vault format, SQLite catalog, scanner, ML derivation, import/sync/send engines — and depends only on GRDB (and links `ImageCaptureCore` for camera access). **`OpenPhotoApp`** is the executable: SwiftUI views plus the central `AppState`, and it depends on `OpenPhotoCore` plus Sparkle for self-update. The dependency direction is strictly one-way (App → Core); Core has no SwiftUI and no knowledge of the UI, which is what lets the on-disk format and engines be specified independently in `docs/format/`. A third throwaway `ICCSpike` executable exists for ImageCaptureCore experiments, and `OpenPhotoCoreTests` covers the library.

The on-disk model is a *self-describing vault* of original files plus a *rebuildable* catalog. A `Vault` (`Sources/OpenPhotoCore/Vault/Vault.swift`) is just a user folder containing a hidden `.openphoto/` state dir (`vault.json` descriptor with a UUID + role, `manifest.jsonl`, `bin/`, `sync-log.jsonl`); originals live unmolested in their normal subfolders. Two side channels carry metadata: human-authored edits (rating, favorite, caption, tags, confirmed face regions) go to per-file **XMP sidecars** under each folder's `.openphoto/` (`SidecarStore`, MWG regions), while machine-derived signals go only to a **SQLite catalog** (`Catalog.swift`, schema v12 via GRDB migrations) holding `assets`, `instances`, `vault_presence`, `embeddings`, `faces`, `geocode`, `phash`, `ocr` (FTS5), and queues like `pending_deletions`. The five hard invariants are enforced structurally: originals are never moved/modified without explicit action; sidecars are authoritative for human data while the catalog is treated as a cache (`ingestSidecars` re-mirrors sidecars on every scan, and `purgeLocalVault` can drop catalog rows knowing they rebuild from disk); nothing hard-deletes — `LibraryService.delete` routes to a `BinStore`; all writes go through `AtomicFile` (temp→fsync→rename) and copies through `VerifiedCopy.copy(...expectedHash:)`; and sync is one-way with passive drives — `Vault.open` is read-only and refuses to write to a drive being inspected.

`LibraryService` (`Sources/OpenPhotoCore/LibraryService.swift`) is the Core façade the UI talks to: it owns the open `Vault`s, the shared `Catalog`, the `ThumbnailStore`, and per-vault sidecar/bin stores, and exposes browse queries (`timelineSections`, `folderTree`, `items(inDir:)`) and edit operations. The **scan/index flow** runs in `Scanner.scan` (`Sources/OpenPhotoCore/Scanner/Scanner.swift`): walk the tree skipping `.openphoto` and opaque packages, fast-path unchanged files by matching size+mtime against the manifest, content-hash the rest, extract embedded metadata for hashes the catalog doesn't know, pair Live Photos, then wholesale-replace `instances` and atomically rewrite the manifest. `LibraryService.scanAll` runs this on a detached utility task per vault and then re-ingests sidecars; a `FolderWatcher` triggers rescans on filesystem change.

The **ML derivation pipeline** is a registry of independent `DerivationStage`s (`Sources/OpenPhotoCore/Derivation/`) — OCR, CLIP embeddings, faces, reverse-geocode, perceptual hash — each owning a `derivation_jobs.stage` row so work is resumable and retry-capped. The runner lives in `AppState.drainDerivation` (`AppState.swift` ~line 1473): it pulls each stage's whole pending set, and for every hash runs the actual inference inside `Task.detached(priority: .utility)` off the main actor, marking each job done/failed in the catalog and yielding between items. `pokeDerivation()` kicks it idempotently at library-open and after any scan. Stages declare `isAvailable` (skip whole stage if model absent) and `needsFile` (geocode reads catalog lat/lon, so it runs even when the drive is unplugged). The **UI data path** is `AppState`, an `@Observable @MainActor` object: views read published arrays (`sections`, `flatItems`, `folderTree`, `people`, `searchResults`, drive state); `refreshQueries()` repopulates them from the catalog, and a `refreshToken` forces invalidation. Every heavy operation — search (SQL + Accelerate + Core ML in `runSearch`), people clustering, cull grouping, drive sync, snapshot I/O — is wrapped in `Task.detached` and only the results are assigned back on the main actor, so the rule is "MainActor holds only observable state and view glue; all I/O, hashing, and inference run detached."

**Import/sync/send** are three separate engines, all hash-verified. Import (`ImportEngine`, with sources for SD/volume, Apple Photos via PhotoKit, Google Takeout, foreign vaults) copies external media into the primary vault. Sync (`SyncEngine.swift`) is the only multi-vault flow and is deliberately merge-free: `plan(...)`/`planClone(...)` diff source manifests against a destination drive's manifest to produce copies/conflicts/sidecar-updates with zero writes, then `apply(...)` does a free-space-guarded, `VerifiedCopy`-checked copy and an atomic manifest rewrite, never overwriting a differing destination file (it becomes a conflict). Send (`SendEngine`) pushes selected items to AirDrop/volume destinations. Drive presence, drift, deletion-propagation, promotion/recovery of canonical vs. backup roles, and catalog *snapshots* (a portable mini-catalog written into a drive's `.openphoto/` for instant adoption on another Mac) are coordinated by `AppState`'s large drives section against `Catalog.vault_presence`.

The principal risk areas a reader should watch: (1) **`AppState` is a 1,700-line god-object** mixing observable UI state with substantial drive/recovery/role-flip orchestration — the highest-churn, hardest-to-test surface, and the place catalog/disk role divergence could creep in. (2) **The catalog-as-cache invariant is load-bearing but only as strong as `ingestSidecars`/`reconcileFinderTags`** — human metadata lives in two places (XMP + catalog columns) and any path that updates one without the other (or a corrupt-but-skipped sidecar) silently diverges. (3) **Memory safety during indexing/derivation** — per MEMORY, indexing has previously OOM'd (autorelease-pool gaps), and the video path, the analysis phase, and single-threaded indexing are still flagged as needing bounded-parallel/memory-safe work; the derivation runner and per-image GPU textures in dense grids are the known hot spots (tile-grid optimization is the remaining Phase 5.5 item). (4) **Sync correctness depends entirely on manifest accuracy and path mapping** — `vault_presence` path rewrites, drive-vs-Mac relpath basename prefixing (`DrivePathMap`), and the "treat any mismatch as a conflict, never overwrite" rule are subtle; a stale or mis-rewritten manifest can strand or duplicate files. (5) Several flows (SD-card send, PhotoKit/Takeout import) are **build-verified only and await hardware smoke tests**, so runtime assumptions there are unproven.

---

## Triage table

| ID | Severity | Area | File | Summary |
|----|----------|------|------|---------|
| C01 | Critical | file-integrity | `LibraryService.swift:229-236` | updateMetadata silently wipes confirmed face regions from the sidecar |
| H01 | High | concurrency | `AppState.swift:1531` | refreshQueries runs full-library DB query + whole-tree filesystem walk on the main actor |
| H02 | High | concurrency | `AppState+FolderReorg.swift:54` | Folder/photo reorg races the off-main scan and can silently revert the manifest |
| H03 | High | memory | `AppState.swift:1489` | No autoreleasepool around per-image decode in the 42k-asset derivation loop |
| H04 | High | performance | `AppState.swift:510` | Search recreates EmbedStage every query, recompiling the Core ML text model and re-parsing the vocab each time |
| H05 | High | concurrency | `ViewerView.swift:241-246` | Full-resolution still is force-decoded on the main thread during view update |
| H06 | High | correctness | `ViewerView.swift:14` | Viewer delete/advance navigates state.flatItems even when browsing a different set (folder/search/people/map) |
| H07 | High | correctness | `Scanner.swift:27-28` | Force-unwrapped FileManager.enumerator() crashes the whole scan on an unreadable/missing root |
| H08 | High | concurrency | `InspectorView.swift:418` | Inspector metadata save does full durable write path synchronously on the main thread |
| H09 | High | correctness | `InspectorView.swift:9` | Unsaved caption is silently discarded when switching photos |
| H10 | High | performance | `DriftReconciler.swift:172` | Bulk drift-repair rewrites the entire manifest once per file |
| H11 | High | file-integrity | `AtomicFile.swift:6` | AtomicFile is not crash-durable: no F_FULLFSYNC and no parent-directory fsync after rename |
| H12 | High | security | `VaultReorganizer.swift:30` | Folder names from the UI are not sanitized for '..' — path traversal can escape the vault root |
| M01 | Medium | concurrency | `AppState.swift:1461` | derivationTask handle can be clobbered to nil by a stale task across close/open |
| M02 | Medium | concurrency | `AppState.swift:1473` | drainDerivation does per-item synchronous catalog writes and two full-table COUNT(*) queries on the main actor |
| M03 | Medium | correctness | `AppState.swift:208` | Async load/search/reverify tasks publish to @Observable state without library-identity or supersession guard (cross-library bleed / stale clobber) |
| M04 | Medium | correctness | `AppState.swift:100` | Pervasive try? / (try? …) ?? [] swallows load failures and can render an empty UI with no error |
| M05 | Medium | correctness | `AppState.swift:1649` | removeOpenedItem advances by flatItems, but the viewer navigates viewerItems |
| M06 | Medium | design | `AppState.swift:51` | AppState is an extreme god object: one @Observable owns the entire app surface |
| M07 | Medium | design | `AppState.swift:199` | facesDirty and geocodeDirty are write-only dead state; People reload uses an empty-check that ignores staleness |
| M08 | Medium | performance | `AppState.swift:1550` | Inspector reads synchronous catalog + jsonl I/O on the MainActor inside view body |
| M09 | Medium | performance | `AppState.swift:1488` | combinedProgress() runs 10 COUNT(*) queries per item on the MainActor during derivation |
| M10 | Medium | concurrency | `AppState+FolderReorg.swift:54` | No re-entrancy guard: overlapping reorg ops can interleave across await points |
| M11 | Medium | correctness | `AppState+FolderReorg.swift:86` | Local catalog/presence/enqueue writes swallow errors with try?, hiding desync from the user |
| M12 | Medium | correctness | `AppState+Undo.swift:52` | Undo of a Live Photo move always shows a false "Couldn't undo" alert |
| M13 | Medium | design | `AppState+FolderReorg.swift:76-79` | Drive propagation, offline queueing, and presence rewrites are uniformly try?-swallowed with no user signal |
| M14 | Medium | SwiftUI | `Catalog+Faces.swift:133` | people() can surface ghost zero-face person cards |
| M15 | Medium | correctness | `Catalog.swift:246-260` | purgeLocalVault leaves orphaned zero-face people rows that surface as empty persons |
| M16 | Medium | correctness | `Catalog.swift:385-412` | rewriteVaultPresencePaths uses a GLOB prefix that mis-handles folders containing glob metacharacters, re-introducing phantom-folder rows after a move |
| M17 | Medium | memory | `Catalog+Embeddings.swift:11-18` | unpackFloat16 silently returns an undersized vector on a short/corrupt blob, enabling an out-of-bounds matrix read in semantic search |
| M18 | Medium | performance | `Catalog+Faces.swift:95` | Face fetches always decode embedding blobs that every UI consumer discards |
| M19 | Medium | SwiftUI | `CleanupView.swift:21-35` | CleanupView recomputes whole-collection derived arrays on every render |
| M20 | Medium | concurrency | `AppState.swift:208` | loadPeople/loadCullGroups spawn uncancelled, untracked detached Tasks → stacked work and stale results |
| M21 | Medium | correctness | `AppState.swift:215` | Catalog read failures in Cull/People loaders are swallowed to empty, with no user-facing error |
| M22 | Medium | correctness | `KeeperSelector.swift:24` | KeeperSelector force-unwraps max(by:) guarded only by a precondition |
| M23 | Medium | performance | `PeopleView.swift:502-508` | Detail views run synchronous catalog DB queries on the main actor in onAppear |
| M24 | Medium | performance | `FaceClusterer.swift:43-60` | FaceClusterer is O(n^2) over the full unassigned-face set, not bounded |
| M25 | Medium | performance | `FaceClusterer.swift:43` | FaceClusterer is O(n²·dim) single-link over an unbounded face set with no cancellation |
| M26 | Medium | correctness | `EmbedStage.swift:216` | Every catalog write in the stages is try?-swallowed, so a write failure is recorded as success |
| M27 | Medium | performance | `AppState.swift:1489` | Derivation drain loop has no autoreleasepool around per-image Core Graphics / Vision / Core ML work across the 42k-asset run |
| M28 | Medium | performance | `GeoNamesLoader.swift:23` | GeoNames loader holds the entire 8.3 MB table as String + full substring array in RAM at once |
| M29 | Medium | performance | `AppState.swift:1456` | GeoNames table loads eagerly on the main actor during AppState construction, blocking launch |
| M30 | Medium | performance | `AppState.swift:510` | Semantic-search query path reconstructs EmbedStage per query, recompiling the text Core ML model each time |
| M31 | Medium | concurrency | `ConsensusRepairSheet.swift:28` | Repair/drift sheets are re-entrant: long async repair leaves trigger buttons live with no progress |
| M32 | Medium | correctness | `ImportView.swift:330` | Failed device enumeration is swallowed and presented as a successful empty grid |
| M33 | Medium | performance | `ImportView.swift:30` | Derived collections recomputed O(n) several times per render in ImportView and FreeUpPhoneView |
| M34 | Medium | performance | `DeviceWatcher.swift:159` | DeviceWatcher.volumesChanged does synchronous Vault.open + fileExists on the MainActor for every removable volume on each mount/unmount |
| M35 | Medium | performance | `DrivesView.swift:115` | DrivesView render and onChange paths run synchronous filesystem I/O and catalog queries per drive |
| M36 | Medium | performance | `ImportView.swift:344` | ImportView rebuilds in-library/imported/sent caches with synchronous full-table catalog scans on the MainActor |
| M37 | Medium | SwiftUI | `MapView.swift:190-197` | Cluster sheet shows the previous cluster's photos and a mismatched count until the async query returns |
| M38 | Medium | SwiftUI | `MapView.swift:377` | Map clusters get a fresh UUID every recompute, destroying annotation identity on every pan/zoom |
| M39 | Medium | SwiftUI | `PeopleView.swift:65-69` | People overview never refreshes when faces change in the background (facesDirty ignored by the view) |
| M40 | Medium | concurrency | `PeopleView.swift:502` | People detail/cluster reload runs per-face synchronous DB queries on the main actor |
| M41 | Medium | correctness | `MapView.swift:190` | Cluster sheet shows stale items from the previously opened cluster |
| M42 | Medium | correctness | `FolderGridView.swift:125` | state.library! force-unwraps crash if the library is torn down while a grid/sheet is visible |
| M43 | Medium | performance | `PeopleView.swift:705-812` | FaceCropView crops on the main actor and caches nothing, repeating fetch+crop per card on every scroll |
| M44 | Medium | performance | `MapView.swift:75-79` | onMapCameraChange reclusters during programmatic fit/zoom animations, and loadAssets' recluster can race the debounced one |
| M45 | Medium | correctness | `ImportEngine.swift:52` | Dictionary(uniqueKeysWithValues:) traps on duplicate ids/paths (Live-pair expansion and verify map) |
| M46 | Medium | correctness | `FreeUpPhoneView.swift:25` | Free-up-phone deletion eligibility uses a metadata fingerprint, not the content hash — collision can delete an un-imported original |
| M47 | Medium | file-integrity | `EmbeddedMetadata.swift:70` | EmbeddedMetadata.embed deletes the staged original before the move and the fetch swallows failure with try? |
| M48 | Medium | performance | `ImportView.swift:230-237` | displayItems recomputed many times per render; O(n×folders) for foreign vaults |
| M49 | Medium | performance | `ImportView.swift:364-379` | rebuildInLibraryCache / rebuildImportedCache do non-scaling catalog+registry work |
| M50 | Medium | correctness | `LibraryService.swift:243-257` | Finder-tag baseline persisted even when the xattr writes it represents failed |
| M51 | Medium | correctness | `LibraryService.swift:70-80` | Sidecar-to-catalog ingest cannot clear metadata when a sidecar becomes empty |
| M52 | Medium | correctness | `LibraryService.swift:303-325` | delete() batch aborts mid-loop on a single enqueue failure, leaving disk/catalog inconsistent |
| M53 | Medium | file-integrity | `XMP.swift:11-63` | XMP serializer emits raw XML-illegal control characters, producing an unparseable sidecar |
| M54 | Medium | performance | `LibraryService+Eviction.swift:138` | Eviction/rehydrate verification re-fetches the entire vault_presence table per item per drive |
| M55 | Medium | performance | `LibraryService.swift:229` | Human-metadata + Finder-tag save path is synchronous and does multi-file disk I/O on the main thread |
| M56 | Medium | performance | `SelectionModel.swift:81` | Rubber-band updateDrag re-scans the entire item list on every drag tick |
| M57 | Medium | correctness | `ViewerView.swift:241-247` | Full-res read/decode failure is silently swallowed with no error state in the main viewer |
| M58 | Medium | correctness | `ViewerView.swift:235-238` | Video AVPlayer is created against a possibly-missing/oversized URL with no readiness or error surface |
| M59 | Medium | design | `PeekView.swift:69` | PeekViewer never tears down its AVPlayer — reintroduces the lingering/doubled-audio leak fixed in ViewerView |
| M60 | Medium | memory | `ViewerView.swift:241-246` | Full original is loaded uncapped into memory with no downsampling or autorelease bounding |
| M61 | Medium | performance | `ViewerView.swift:241` | Full-image decode runs on the main actor in both viewers |
| M62 | Medium | performance | `ThumbnailImage.swift:34` | Per-tile GPU texture blowup drives dense-grid lag (known, deferred) |
| M63 | Medium | performance | `TimelineView.swift:18` | TimelineView.body re-scans the full timeline list multiple times per render |
| M64 | Medium | SwiftUI | `AppState.swift:485` | Search result race: overlapping un-cancelled Tasks can publish stale results |
| M65 | Medium | correctness | `Catalog+Search.swift:119` | Entire search path swallows errors via try? → silent empty/partial results, no user-facing failure |
| M66 | Medium | correctness | `SemanticIndex.swift:18-22` | SemanticIndex trusts declared dim over decoded vector length → vDSP_mmul out-of-bounds |
| M67 | Medium | design | `AppState.swift:490` | Silent error swallowing across the search pipeline hides failures as empty results |
| M68 | Medium | performance | `AppState.swift:490` | Loose filters / empty-query path materializes the whole library into Swift arrays and a giant IN(?) bind list |
| M69 | Medium | concurrency | `FolderWatcher.swift:55-61` | FolderWatcher.stop() may run off the owning context via deinit, and the FSEvents callback can fire during teardown |
| M70 | Medium | correctness | `Scanner.swift:64-67` | Manifest fast-path can silently miss content edits (size+mtime unchanged) |
| M71 | Medium | correctness | `Scanner.swift:48-52` | Scan silently drops files on attribute/read errors with no user-facing surfacing |
| M72 | Medium | performance | `PresenceService.swift:45-95` | PresenceService.locations() amplifies into O(items × drive-vaults) full-set SQL reads |
| M73 | Medium | performance | `Scanner.swift:29-53` | Scan pipeline is fully single-threaded (serial walk, hash, and metadata extract) |
| M74 | Medium | SwiftUI | `InspectorView.swift:129` | Synchronous DB queries run inside InspectorView.body on every recomputation |
| M75 | Medium | correctness | `CleanupView.swift:33-46` | CleanupView selection re-seed key ignores group membership changes |
| M76 | Medium | correctness | `InspectorView.swift:41` | In-progress caption / new-tag text is lost when switching photos (no debounce or flush) |
| M77 | Medium | correctness | `InspectorView.swift:234` | Inspector Delete/Evict advances within flatItems, not the viewer's actual item set |
| M78 | Medium | correctness | `InspectorView.swift:420` | Sidecar/catalog write failures in Inspector are swallowed with no user-facing error |
| M79 | Medium | performance | `InspectorView.swift:418-426` | Metadata save blocks the main actor with file I/O and a full library re-query |
| M80 | Medium | correctness | `VolumeCopyDestination.swift:38` | No free-space preflight before volume copy-out |
| M81 | Medium | correctness | `SendEngine.swift:31` | Swallowed enumeration failure silently disables dedup and re-copies everything |
| M82 | Medium | file-integrity | `VolumeCopyDestination.swift:50` | fsync durability check is bypassed when the file handle cannot be opened |
| M83 | Medium | correctness | `BinView.swift:38` | Bin "Restore" swallows its error — failed restores silently do nothing |
| M84 | Medium | correctness | `BinView.swift:38-43` | Bin restore failures are swallowed silently |
| M85 | Medium | design | `BinView.swift:53-71` | Empty-Bin flow bypasses LibraryService/BinStore and manipulates the bin on disk directly |
| M86 | Medium | correctness | `SyncEngine.swift:187` | Final manifest rewrite in apply() is swallowed by try?, losing the record of copied files |
| M87 | Medium | correctness | `Manifest.swift:50` | One corrupt manifest line aborts the whole read, making a drive look empty |
| M88 | Medium | file-integrity | `DriftReconciler.swift:7` | Drive yanked mid-walk corrupts presence by reporting good files as missing |
| M89 | Medium | performance | `AppState.swift:1234` | Adopt/restore/acknowledge run file hashing and manifest rewrites on the main actor |
| M90 | Medium | performance | `AppState.swift:1289` | goodCopyURL re-reads every drive's full manifest per finding in repair loops |
| M91 | Medium | correctness | `BinStore.swift:21` | BinStore.moveToBin/restore silently no-op when destination already occupied; failures swallowed at call sites |
| M92 | Medium | correctness | `Manifest.swift:60` | Manifest/BinStore JSONL parse aborts entire file on a single malformed line |
| M93 | Medium | design | `Manifest.swift:60-62` | One malformed line makes the whole manifest / bin log unreadable, and callers silently treat it as empty |
| M94 | Medium | file-integrity | `VaultReorganizer.swift:79` | Collision-adjusted move recomputes relPath via symlink-resolving relativePath(), risking a bogus absolute manifest path |
| M95 | Medium | performance | `BinStore.swift:36-39` | Bin log is fully re-parsed and rewritten on every single delete/restore (O(N^2) batches) with no caching |
| L01 | Low | concurrency | `AppState.swift:208` | loadPeople / loadCullGroups / runSearch have no generation guard — a stale async result can overwrite a newer one |
| L02 | Low | design | `AppState.swift:51` | God object: AppState concentrates library, queries, watchers, derivation, drives, search, people, cull, send and undo in one ~1740-line @MainActor type |
| L03 | Low | file-integrity | `AppState.swift:300` | Concurrent people-management ops have an unserialized read-modify-write window on a shared sidecar |
| L04 | Low | security | `AppState.swift:120` | tagsForSave / runSearch / structuredFilter feed unvalidated external metadata into search and sidecars |
| L05 | Low | SwiftUI | `AppState.swift:1536-1543` | refreshQueries auto-expands the entire folder tree whenever expandedFolders is empty |
| L06 | Low | concurrency | `AppState+Undo.swift:14` | applyUndo's isApplyingUndo flag can suppress a legitimate concurrent recordUndo |
| L07 | Low | design | `AppState+FolderReorg.swift:23-25` | Drive-relpath and parent-path mapping logic is triplicated |
| L08 | Low | design | `AppState+Undo.swift:16` | recordUndo reconfigures levelsOfUndo on every registration |
| L09 | Low | performance | `AppState+FolderReorg.swift:134-140` | Per-drive x per-file nested propagation loops on the main path |
| L10 | Low | correctness | `Catalog.swift:246-260` | purgeLocalVault does not clear pending_folder_ops queued against the purged vault |
| L11 | Low | correctness | `Catalog.swift:214-231` | setCanonical/setVaultLastSeen UPDATE-by-id silently no-op on a missing id; setCanonical can leave zero canonicals |
| L12 | Low | design | `Catalog+Derivation.swift:9` | Dead eligibleKind(forStage:) switch — every branch returns the same value |
| L13 | Low | design | `Catalog+Embeddings.swift:6` | Float16 pack/unpack helpers duplicated verbatim across two files |
| L14 | Low | design | `Catalog+Faces.swift:85` | Long face column-list SQL duplicated across three fetch methods |
| L15 | Low | design | `Catalog+Faces.swift:24` | Stale doc comment: representativeFaceID is not filtered to confirmed faces |
| L16 | Low | performance | `Queries.swift:33` | All Catalog reads are synchronous DB calls; several SwiftUI consumers run them on the main actor |
| L17 | Low | correctness | `BurstGrouper.swift:13` | BurstGrouper chains consecutive frames so a slow pan exceeds the intended 60s window |
| L18 | Low | correctness | `Catalog+Embeddings.swift:11` | Float16 unpack truncates short blobs to a wrong-length vector instead of failing |
| L19 | Low | design | `KeeperSelector.swift:25-37` | Duplicated tiebreaker logic and magic thresholds across the cull algorithms |
| L20 | Low | design | `AppState.swift:254` | EmbedStage allocated solely to read a constant modelID in the cull path |
| L21 | Low | performance | `DuplicateGrouper.swift:15-23` | DuplicateGrouper union-find lacks path compression / union-by-rank and is O(n^2) per folder |
| L22 | Low | correctness | `CLIPTokenizer.swift:276` | gunzip output buffer sized from gzip ISIZE field truncates silently if the stream is larger |
| L23 | Low | design | `AppState.swift:254` | modelID resolved via throwaway EmbedStage() at several call sites — duplicated, fragile constant access |
| L24 | Low | memory | `EmbedStage.swift:162` | EmbedStage and PHashStage/Face decode the source at full resolution before downsizing |
| L25 | Low | memory | `GeoNamesLoader.swift:46` | GeoNamesLoader holds the full city table in RAM with no lifecycle bound |
| L26 | Low | correctness | `FreeUpPhoneView.swift:88` | Empty-trash button label/count is read at a different time than the delete confirmation |
| L27 | Low | correctness | `DeviceWatcher.swift:75` | ICDeviceTypeMask force-unwrap on a hardcoded raw mask |
| L28 | Low | correctness | `ImportView.swift:139` | source! force-unwrap in import grid relies on an implicit phase invariant |
| L29 | Low | design | `DeviceWatcher.swift:188` | Manual-volume detection relies on a hard-coded id-prefix string literal that duplicates the enum's id-construction |
| L30 | Low | design | `FreeUpPhoneView.swift:178` | No tests around destructive drive/device flows |
| L31 | Low | correctness | `FolderGridView.swift:141` | FolderGridView.reload swallows catalog errors with no user-facing failure state |
| L32 | Low | correctness | `PeopleView.swift:65` | People overview does not refresh when faces become dirty while already on screen |
| L33 | Low | design | `MapView.swift:351-390` | Pure grid-clustering math (MapView.cluster) has no unit test despite tricky float bucketing and centroid logic |
| L34 | Low | design | `FolderTreeView.swift:27-30` | Root drop target declared twice with duplicated handling logic |
| L35 | Low | performance | `FolderGridView.swift:193-204` | Folder picker walks the entire folder tree on every render while in select mode |
| L36 | Low | performance | `MapView.swift:377` | Map clusters get a fresh UUID on every recluster, forcing full annotation/thumbnail rebuild on each pan-zoom |
| L37 | Low | performance | `MapView.swift:166-173` | zoomIntoCluster filters all assets with an O(n·m) array-contains lookup |
| L38 | Low | concurrency | `ImportView.swift:188` | In-flight import has no cancellation path and the engine never checks Task cancellation |
| L39 | Low | correctness | `PhotosLibrarySource.swift:47` | PhotosLibrarySource resource fileSize KVC can yield 0, weakening size-based fingerprints |
| L40 | Low | correctness | `ImportEngine.swift:97` | Skipped-duplicate registry append and metadata-fold errors are swallowed with try? |
| L41 | Low | correctness | `TakeoutJSONMatcher.swift:9` | Takeout JSON matching misses truncation combined with the (n) counter and double-extension variants |
| L42 | Low | design | `VolumeSource.swift:97-106` | Duplicated EXIF-date, thumbnail-options, and read-only-delete logic across sources |
| L43 | Low | design | `PhotosLibrarySource.swift:121-125` | Takeout/Photos '(edited)' naming and JSON matching are fragile and untested for collisions |
| L44 | Low | security | `TakeoutSource.swift:17` | Full filesystem paths embedded in sourceKey and raw error strings surfaced to UI/registry |
| L45 | Low | correctness | `LibraryService.swift:327-336` | restore() treats an unknown-vault no-op as success and dequeues the pending deletion |
| L46 | Low | design | `LibraryService+Move.swift:31` | Move-failure surface stringifies raw Swift errors into a user-facing dictionary |
| L47 | Low | design | `SidecarStore.swift:16` | XMP-serialize-and-atomic-write logic is duplicated across three sites |
| L48 | Low | correctness | `ViewerView.swift:14-17` | Live-photo and grouped-step assume openedItem still exists in the list; defensive only |
| L49 | Low | performance | `ViewerView.swift:17` | step() / index recompute a full-array linear scan in body and on every navigation |
| L50 | Low | correctness | `DatePreset.swift:11` | DatePreset force-unwraps Calendar.date results — crash on calendar/year-math edge cases |
| L51 | Low | correctness | `Catalog+Search.swift:164-181` | IN(...) / OR fan-out has no chunking against SQLite host-variable limit on large libraries |
| L52 | Low | design | `Queries.swift:18` | Drive-only dedup-by-MIN(rowid) SQL is duplicated between the timeline union and folderCounts |
| L53 | Low | performance | `SemanticIndex.swift:36` | SemanticIndex.query sorts all scores instead of partial top-N selection |
| L54 | Low | correctness | `MetadataExtractor.swift:44-55` | extractImage GPS/Exif reads assume exact dynamic types; live-pair contentIdentifier key is fragile |
| L55 | Low | design | `BackupProbe.swift:6-24` | BackupProbe is dead production code duplicating PresenceService's API |
| L56 | Low | design | `Scanner.swift:27-28` | Force-unwrapped fm.enumerator()! can crash the scan |
| L57 | Low | design | `LivePhotoPairer.swift:31-32` | Live Photo pairing depends on non-deterministic filesystem enumeration order |
| L58 | Low | SwiftUI | `ProFilterBar.swift:38-43` | Filter-bar facet load uses an id-less .task that never refreshes after library changes |
| L59 | Low | correctness | `InspectorView.swift:230` | Duplicate-hash photo switch does not reload Inspector editable state |
| L60 | Low | correctness | `SearchView.swift:119` | state.library! force-unwrapped in Search and Cleanup tile construction |
| L61 | Low | design | `ProFilterBar.swift:358-379` | Duplicated filter-bar helpers and chip styling across Simple/Pro bars |
| L62 | Low | design | `DatePreset+UI.swift:23-26` | recentYears couples to the relative-preset list via a hardcoded -2 offset |
| L63 | Low | SwiftUI | `TimelineView.swift:66` | connectedSendTargets recomputed in body with per-volume IO |
| L64 | Low | design | `SendEngine.swift:80` | Present-match logic duplicated across engine and reverifier |
| L65 | Low | file-integrity | `DeviceRegistry.swift:66` | DeviceRegistry silently drops a record on per-entry encode failure |
| L66 | Low | memory | `VolumeCopyDestination.swift:21` | enumeratePresent re-hashes every file on the volume with no per-file autoreleasepool or cancellation |
| L67 | Low | performance | `SendRegistry.swift:57` | Registry queries are full linear scans in hot loops |
| L68 | Low | SwiftUI | `OpenPhotoApp.swift:9-10` | Sparkle updater held as plain `let` instead of `@State` on the App |
| L69 | Low | concurrency | `SettingsView.swift:67` | Settings library-size aggregate query runs synchronously on the main actor |
| L70 | Low | correctness | `BinView.swift:32` | Fragile state.library! force-unwraps in Bin and Send views |
| L71 | Low | file-integrity | `BinView.swift:60` | Empty-bin can leave a stale bin log if the log rewrite fails after a successful trash |
| L72 | Low | performance | `SendSheet.swift:63-65` | Send warning view recomputes grouping + per-group filtering on every render |
| L73 | Low | performance | `WindowControls.swift:62` | scheduleReposition() self-reschedules forever with no cap if the view never attaches to a window |
| L74 | Low | correctness | `CatalogIngest.swift:46` | DrivePathMap.driveToMacRelPath silently mismaps when a Mac source root basename collides with a sub-folder name |
| L75 | Low | correctness | `SyncEngine.swift:128` | Free-space guard ignores sidecar bytes (and snapshot/manifest overhead) |
| L76 | Low | correctness | `CatalogSnapshot.swift:89` | PeekSource.import / verifyAdoption call replaceVaultPresence, clobbering live verified presence with snapshot-derived data |
| L77 | Low | correctness | `CatalogSnapshot.swift:112` | Snapshot/peek read paths swallow all errors, masking unreadable or corrupt snapshots |
| L78 | Low | design | `SyncEngine.swift:28` | Duplicated diff and sidecar-path logic across plan/planClone and propagate/deleteDriveOnly |
| L79 | Low | performance | `SyncLog.swift:5` | SyncLog.append rewrites the whole log file on every append |
| L80 | Low | correctness | `BinStore.swift:42-56` | restore() drops ALL bin-log entries sharing a relPath and has no collision handling at the restore target |
| L81 | Low | design | `VaultDescriptor.swift:47-57` | Redundant non-lenient ISO8601 parser is a silent foot-gun (mtime falls back to now) |

---

## Findings

## Critical

### C01 — updateMetadata silently wipes confirmed face regions from the sidecar

- **Severity:** Critical
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:229-236`, `Sources/OpenPhotoCore/Sidecar/SidecarData.swift:12-21`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:418-426`, `Sources/OpenPhotoApp/AppState.swift:137-138`, `Sources/OpenPhotoApp/AppState.swift:441-470`
- **Problem:** updateMetadata builds `SidecarData(rating:favorite:caption:tags:)` which defaults `faces: []`, then writes it over the existing sidecar via SidecarStore.write -> AtomicFile.write. It never reads the current sidecar to preserve faces. So any rating/favorite/caption/tag edit in the Inspector (InspectorView.save -> updateMetadata) OR a Finder-tag reconcile that changes tags (AppState.syncFinderTagsNow -> updateMetadata) destroys all confirmed <mwg-rs:Regions> face regions previously written to that sidecar. The face-writing path (AppState.rewriteSidecarForHash) deliberately does a read-modify-write to keep other fields; updateMetadata is the inverse and clobbers faces. This is human-authored metadata loss and violates hard invariant 2 (human metadata lives in sidecars). After the next rescan/ingest the catalog face state may still exist, but the portable, sovereign on-disk record is gone and a SidecarExporter run would export the face-less version.
- **Suggested fix:** Make updateMetadata read-modify-write like rewriteSidecarForHash: load the existing SidecarData (or .empty), mutate only rating/favorite/caption/tags, and keep `faces` intact before writing. Equivalently, have updateMetadata accept and thread through the existing faces, or route all sidecar writes through a single merge helper that never drops fields it wasn't asked to change.
- **Verification:** Confirmed: updateMetadata (LibraryService.swift:231) constructs SidecarData with faces defaulting to [] and writes it via SidecarStore.write -> AtomicFile.write, a full overwrite; XMP.serialize omits the <mwg-rs:Regions> block when faces is empty (XMP.swift:26), so every Inspector edit or Finder-tag reconcile wipes confirmed face regions from the sidecar. The parallel face path rewriteSidecarForHash deliberately read-modify-writes to preserve fields, confirming the asymmetry; loss is recoverable via catalog state on a later face op but the portable on-disk record (and any exportSidecars run) is clobbered, violating invariant 2. (Confirmed on adversarial verification.)
- **Effort:** S

## High

### H01 — refreshQueries runs full-library DB query + whole-tree filesystem walk on the main actor

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1531`, `Sources/OpenPhotoApp/AppState.swift:1533`, `Sources/OpenPhotoApp/AppState.swift:1535`, `Sources/OpenPhotoApp/AppState.swift:1544`, `Sources/OpenPhotoCore/LibraryService.swift:88`, `Sources/OpenPhotoCore/LibraryService.swift:178`, `Sources/OpenPhotoCore/LibraryService.swift:150`
- **Problem:** refreshQueries() is @MainActor and synchronously calls library.timelineSections (loads the entire library's TimelineItems and groups them by date), library.folderTree (which calls directoriesUnder() -> FileManager.enumerator walking the ENTIRE library root on disk, plus a folderCounts SQL aggregate), and library.binItems. It is invoked on nearly every state change: videoOnly/grouping toggles, every delete/rename/evict/rehydrate, every drift scan, every sync/clone/promote/recover, finder-tag sync completion, derivation finishing, device reverify, etc. On a 10k+ photo library on a slow/external/network volume, the directory enumeration alone can stall the main thread for seconds, freezing the whole UI. This is the central god-object hazard.
- **Suggested fix:** Move the heavy reads off-main: compute sections/flatItems/folderTree/binEntries inside a Task.detached(priority:.userInitiated) and publish the results back on MainActor (the loadPeople/loadCullGroups pattern already used in this file). At minimum, cache/skip the filesystem directoriesUnder() walk and only rebuild it when the watcher reports a structural change, rather than on every metadata-level refreshQueries call.
- **Verification:** Verified: AppState is @Observable @MainActor (line 51-52), so refreshQueries() (AppState.swift:1531) runs on the main actor and synchronously calls library.timelineSections (full-library DB load + date grouping), library.folderTree (LibraryService.swift:178 → directoriesUnder at :150 does a synchronous FileManager.enumerator walk of the entire vault root with per-URL resourceValues plus a folderCounts SQL aggregate), and library.binItems, with ~15 trigger call sites. Unlike loadPeople/loadCullGroups which use Task.detached(.userInitiated), this heavy I/O is never moved off-main, so a large or slow/network volume can stall the UI for seconds. (Confirmed on adversarial verification.)
- **Effort:** M

### H02 — Folder/photo reorg races the off-main scan and can silently revert the manifest

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:54`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:59`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:109`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:117`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:222`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:266`, `Sources/OpenPhotoApp/AppState.swift:1438`, `Sources/OpenPhotoCore/LibraryService.swift:60`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:60`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:143`
- **Problem:** rescan() runs Scanner.scan inside Task.detached(.utility) off the MainActor. The scan reads manifest.jsonl (Scanner.swift:60), walks the directory tree, then at the very end rewrites the catalog instances and Manifest.write()s the manifest from its stale in-memory snapshot (Scanner.swift:143). None of moveFolder/movePhotos/createFolder/deleteFolder gates on `scanning`; they run on the MainActor during the scan's `await` and synchronously move directories on disk AND read+rewrite the same manifest.jsonl via VaultReorganizer. If a reorg lands between the scanner's manifest read and its final Manifest.write, the scanner's stale write overwrites the reorganizer's manifest changes: the directory is physically moved on disk but the manifest (and the catalog replaceInstances) still point at the old paths. This is a same-file, two-writer race with no lock. It is reachable in normal use because scans are kicked by drive-connect, file-watch events, and the trailing rescan() of a prior reorg, while the user can keep dragging folders. Result is a manifest/disk desync that persists until the next clean rescan, and during the window the moved assets appear missing.
- **Suggested fix:** Serialize reorg against scanning. Simplest: at the top of moveFolder/movePhotos/createFolder/deleteFolder, `guard !scanning` (and disable the Folders drag/drop + context actions while `state.scanning`), or await a shared reorg/scan actor/lock so the disk+manifest mutation and the scan never overlap. Longer term, route all manifest writes through a single serialized owner (e.g. an actor) so VaultReorganizer and Scanner cannot interleave writes to manifest.jsonl.
- **Verification:** Verified: AppState is @MainActor; Scanner.scan runs off-main via Task.detached(.utility) in LibraryService.scanAll, reading manifest.jsonl at Scanner.swift:60 and doing a wholesale replaceInstances + atomic Manifest.write at :142-143 after a long async window (MetadataExtractor.extract). The reorg methods synchronously move directories and rewrite the same manifest via VaultReorganizer (e.g. moveFolder line 59 -> rewriteManifest read+write) on the MainActor with no `!scanning` guard, so a reorg landing during an in-flight scan is cleanly clobbered by the scanner's stale last-writer-wins write, leaving disk moved but manifest/catalog pointing at old paths; worse, the reorg's own trailing rescan() early-returns on `guard !scanning`, so there's no guaranteed self-heal. Real same-file two-writer race; severity is correctly High though it is timing-dependent. (Confirmed on adversarial verification.)
- **Effort:** M

### H03 — No autoreleasepool around per-image decode in the 42k-asset derivation loop

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** memory
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1489`, `Sources/OpenPhotoApp/AppState.swift:1498`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:161`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:167`, `Sources/OpenPhotoCore/Derivation/FaceStage.swift:20`, `Sources/OpenPhotoCore/Derivation/OCRStage.swift:14`, `Sources/OpenPhotoCore/Cull/PerceptualHash.swift:11`
- **Problem:** The runner drains each stage's WHOLE pending set (the full 42k assets) in a tight `for hash in pending` loop, and every iteration runs `stage.run` inside a `Task.detached(.utility)`. Each stage body allocates ImageIO/CoreGraphics/Vision objects that are autoreleased, not ARC-released: `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex` decode the FULL-resolution source CGImage (FaceStage:22-23, EmbedStage:162-163, PerceptualHash:12-13), VNImageRequestHandler/VNFeaturePrintObservation and the observation's `.data` CFData (FaceStage:66, OCRStage), and CVPixelBuffer (EmbedStage:172). None of this is wrapped in `autoreleasepool`. A Swift async/detached Task does not drain the thread's autorelease pool between loop iterations the way a runloop turn does, so autoreleased full-res images accumulate across thousands of assets. This is the exact mechanism that previously drove indexing to 41GB and crashed the Mac (per project memory: missing autorelease pools). The serial await prevents *live* object pile-up but does nothing for *autoreleased* objects.
- **Suggested fix:** Wrap the per-image work in an explicit pool. Cleanest is inside each stage's pixel/decode helper, e.g. in EmbedStage.makePixelBuffer / FaceStage.detect / OCRStage.recognizeText / PerceptualHash.compute: `return autoreleasepool { ... }`. Belt-and-suspenders: also wrap the body of the detached closure at AppState.swift:1498 in `autoreleasepool { ... }` so every job iteration drains regardless of stage. Verify with a long run under Instruments Allocations that resident memory stays flat across the pending set.
- **Verification:** Verified: the derivation loop (AppState.swift:1489-1509) serially drains the full ~42k pending set, each job running synchronous ImageIO/Vision/CoreGraphics work (full-res CGImageSourceCreateImageAtIndex in FaceStage:22-23 and EmbedStage:162-163, CVPixelBuffer, VNFeaturePrintObservation/CFData) inside a Task.detached(.utility) with no autoreleasepool anywhere in the derivation/cull path (grep confirms pools exist only in the three scan-phase leaf fns). Cooperative-thread detached closures have no runloop turn to drain autoreleased temporaries between iterations, so they accumulate across thousands of assets — the same mechanism that drove this app to 41GB RSS and a kernel panic in the scan phase (commit 4cc805f), and explicitly logged as the still-unfixed "derivation phase NOT memory-pressure-aware" residual. (Confirmed on adversarial verification.)
- **Effort:** S

### H04 — Search recreates EmbedStage every query, recompiling the Core ML text model and re-parsing the vocab each time

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:510`, `Sources/OpenPhotoApp/AppState.swift:503`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:67`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:104`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:115`
- **Problem:** performSearch builds `EmbedStage()` inline on every settled query (line 510) and calls embedText on it. EmbedStage memoizes its model/tokenizer per-instance, but the instance is thrown away after each search, so the memoization never helps the query path. Each search therefore: (a) runs MLModel.compileModel + MLModel(contentsOf:) on mobileclip_s2_text.mlpackage from scratch, and (b) rebuilds CLIPTokenizer — inflating the 1.36 MB gzip vocab, splitting 48,895 merge lines, and constructing a 49,408-entry encoder dictionary. None of this is shared with the registry's EmbedStage at line 1457 (a separate instance). The result is hundreds of ms of avoidable model-compile + vocab-parse latency on every text search, defeating the lazy-load design entirely. (Search is debounced in SearchView, so it is once-per-settled-query, not per keystroke — which is why this is High, not Critical.)
- **Suggested fix:** Hold a single shared EmbedStage on AppState (e.g. `private let embed = EmbedStage()`) and reuse it for both the registry and query-time embedText/modelID, so the model and tokenizer compile/parse exactly once per process. Pass that instance into the detached search closure. As a bonus this also makes `.modelID` lookups at lines 254/503/1350 free instead of allocating throwaway stages.
- **Verification:** Confirmed: AppState.swift:510 builds a throwaway `EmbedStage()` and calls `embedText(q)` on every settled non-empty query; EmbedStage memoizes the text model and tokenizer per-instance (triedTextLoad/triedTokenizerLoad), so a fresh instance re-runs MLModel.compileModel+MLModel(contentsOf:) and rebuilds CLIPTokenizer (gunzip vocab, parse ~48894 merges, build ~49408-entry encoder, with no process-level cache) each search, and this instance is never shared with the registry's EmbedStage at line 1457. The line-503/254/1350 .modelID lookups also allocate throwaway stages but only read a static string (no compile/parse), so they're a minor bonus, not the core cost. (Confirmed on adversarial verification.)
- **Effort:** S

### H05 — Full-resolution still is force-decoded on the main thread during view update

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:241-246`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:313-321`, `Sources/OpenPhotoApp/Peek/PeekView.swift:135-136`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:292`
- **Problem:** loadFull() offloads only Data(contentsOf:) to a detached task, then builds NSImage(data:) on the @MainActor. NSImage(data:) is lazy and decodes nothing until drawn, so the expensive full-resolution pixel decode is deferred. That decode is then forced synchronously on the main thread inside ZoomPanLayerView.setImageIfChanged via image.cgImage(forProposedRect:context:hints:) (ViewerView.swift:317), which runs from makeNSView/updateNSView (main-actor). For a modern camera original (40-100+ MP, RAW, HEIC) this blocks the main thread for hundreds of ms on every viewer open and every arrow-key step, causing a visible UI stall / dropped frames. PeekViewer has the identical structure (PeekView.swift:135-136 -> ZoomableImageView at 110). The detached Data read does not actually move the cost off-main; it just moves I/O while leaving the heavy decode on-main.
- **Suggested fix:** Decode to a CGImage off the main thread before handing it to the view. In the detached task, create a CGImageSource from the URL and call CGImageSourceCreateImageAtIndex (optionally CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize sized to the display/backing pixel bounds) so the pixels are fully realized off-main; pass the (Sendable) CGImage to the view and set it directly as the CALayer contents, instead of constructing an NSImage and letting AppKit decode lazily on draw. This also lets you cap the decoded size (see the unbounded-memory finding).
- **Verification:** Confirmed in code: loadFull() only offloads Data(contentsOf:) to a detached task (ViewerView.swift:241-243, PeekView.swift:135) and builds the lazy NSImage(data:) on @MainActor; the full-res pixel decode is then forced synchronously on the main actor via image.cgImage(forProposedRect:context:hints:) inside ZoomPanLayerView.setImageIfChanged (ViewerView.swift:317), which is invoked from NSViewRepresentable make/updateNSView. A fresh NSImage instance per open/arrow-step means the !== guard doesn't amortize it, so the heavy decode runs main-thread on every viewer open and navigation step. (Confirmed on adversarial verification.)
- **Effort:** M

### H06 — Viewer delete/advance navigates state.flatItems even when browsing a different set (folder/search/people/map)

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:14`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:208`, `Sources/OpenPhotoApp/AppState.swift:1649`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:234`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift:134`, `Sources/OpenPhotoApp/Search/SearchView.swift:129`, `Sources/OpenPhotoApp/People/PeopleView.swift:407`, `Sources/OpenPhotoApp/Map/MapView.swift:149`, `Sources/OpenPhotoApp/Map/MapView.swift:252`
- **Problem:** ViewerView navigates the set it was opened with: `flatItems` returns `state.viewerItems` when non-empty (set by openViewer), and step()/index/filmstrip all use that. But the shared cull path `removeOpenedItem` (used by the viewer's keyboard Delete and the inspector Delete/Evict buttons) advances strictly within `state.flatItems` (the timeline ordering), ignoring `viewerItems`. The viewer is opened with non-timeline sets from Folders (`items`), Search (`searchResults`), People (face `photos`), and Map (`[item]` or `sheetItems`). In those contexts, deleting the on-screen photo jumps to whatever happens to be next in the global timeline rather than the next photo in the folder/search/person the user is actually browsing — and if the opened item isn't found in `flatItems` (e.g. a Map single-item open, or a face photo not in the current timeline filter such as video-only mode), it closes the viewer instead of advancing. Culling through a folder/person from the viewer therefore misbehaves.
- **Suggested fix:** Make removeOpenedItem operate on the same list the viewer is using. Either pass the active list in (e.g. `removeOpenedItem(in list: [TimelineItem], using:)` and have callers supply `viewerItems.isEmpty ? flatItems : viewerItems`), or have AppState compute the active list the same way ViewerView.flatItems does. Then advance within that list and also remove the deleted item from `viewerItems` so the filmstrip stays consistent.
- **Verification:** Confirmed: ViewerView.flatItems (lines 14-16) navigates state.viewerItems when set, but removeOpenedItem (AppState.swift:1649-1658) advances strictly within state.flatItems and never updates viewerItems. Since openViewer is called with non-timeline sets from Folders/Search/People/Map (verified at the cited call sites) and both the viewer keyboard Delete and the inspector Delete/Evict (InspectorView:234,242) route through removeOpenedItem, deleting while browsing a folder/search/person jumps to the wrong (timeline) neighbor, and a not-in-timeline open (e.g. Map within:[item]) closes the viewer instead of advancing. (Confirmed on adversarial verification.)
- **Effort:** M

### H07 — Force-unwrapped FileManager.enumerator() crashes the whole scan on an unreadable/missing root

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/Scanner.swift:27-28`
- **Problem:** `fm.enumerator(at: vault.rootURL, ...)!` is force-unwrapped. FileManager.enumerator returns nil when the URL is not a reachable directory (root deleted, on an ejected/unmounted external vault, permission denied after a security-scoped bookmark went stale). Because scan runs inside a Task.detached, this becomes an unhandled fatalError / trap that crashes the indexing task rather than surfacing a recoverable error. Given vaults can live on removable drives and bookmarks can go stale, this is a realistic crash, not a theoretical one.
- **Suggested fix:** `guard let enumerator = fm.enumerator(at: vault.rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw <a typed error, e.g. ScanError.rootUnreadable> }`. Let the caller present a user-facing 'vault unavailable' state instead of trapping.
- **Verification:** Scanner.swift:27-28 force-unwraps fm.enumerator(at: vault.rootURL, ...)!, and FileManager.enumerator(at:) is documented to return nil when the URL is not a reachable directory (missing root, ejected/unmounted external vault, or permission-denied via a stale security-scoped bookmark — all realistic since vaults live on removable drives). The whole function is otherwise deliberately hardened with per-file try/catch and the caller LibraryService.scanAll is async throws, so a thrown error would be recoverable; instead the force-unwrap traps with a fatalError that crashes the process. Defect is real as described. (Confirmed on adversarial verification.)
- **Effort:** S

### H08 — Inspector metadata save does full durable write path synchronously on the main thread

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:418`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:51`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:61`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:85`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:98`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:44`, `Sources/OpenPhotoCore/LibraryService.swift:229`, `Sources/OpenPhotoCore/LibraryService.swift:243`, `Sources/OpenPhotoApp/AppState.swift:120`, `Sources/OpenPhotoApp/AppState.swift:1531`
- **Problem:** save() is called from every rating button, the favourite toggle, each tag add/remove and the caption onSubmit, all of which run on @MainActor. save() then synchronously invokes lib.updateMetadata (SidecarData.write — temp→fsync→rename — plus catalog.updateHumanMetadata), tagsForSave→reconcileFinderTags (which enumerates every local instance file, reads Finder xattrs from each, JSON-encodes, writes xattrs back to EVERY file, and writes a baseline), and finally state.refreshQueries() which re-runs timelineSections + folderTree + binItems against the catalog. None of this is moved off the main actor. On a large library or a slow/spinning external drive, each star click or tag edit blocks the UI for the duration of multiple file writes and a full timeline re-query — a visible hang and beachball per interaction.
- **Suggested fix:** Move the write + reconcile + requery off the main actor: capture the edited values, then `Task.detached` to call updateMetadata/reconcileFinderTags, and hop back to @MainActor only to refresh the opened item / queries. Debounce rapid rating/caption changes (see the lost-edit finding) and coalesce refreshQueries so it runs once after a burst of edits rather than per keystroke/click.
- **Verification:** Confirmed: save() is a @MainActor View method wired to every rating/favorite/tag/caption action; it synchronously calls lib.updateMetadata (AtomicFile.write does a real FileHandle.synchronize() fsync + replaceItemAt, plus a catalog DB write) and state.refreshQueries() (re-runs timelineSections, folderTree — which also does a full filesystem directory walk via directoriesUnder — and binItems), all inline on the main thread since LibraryService is a plain Sendable class, not an actor. The reconcileFinderTags enumerate/read/write-xattr-to-every-file path is gated behind finderTagSyncEnabled (off by default), but the fsync + DB write + full requery (with filesystem enumeration) per interaction still blocks the UI; the codebase offloads the equivalent bulk work elsewhere (syncFinderTagsNow uses Task.detached) but not here. (Confirmed on adversarial verification.)
- **Effort:** M

### H09 — Unsaved caption is silently discarded when switching photos

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:9`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:40-45`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:230`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:398-404`
- **Problem:** The caption is edited into local @State `caption` and only persisted on `.onSubmit`. The TextField uses `axis: .vertical`, so pressing Return inserts a newline rather than reliably firing onSubmit, and there is no commit on focus-loss. When the user navigates to the next/previous photo (arrow keys or filmstrip), `state.openedItem` changes → InspectorView gets a new `item` → `.task(id: item.hash)` runs `load()`, which overwrites `caption` with the new item's value. Any typed-but-unsubmitted caption is lost with no warning. Rating/favorite/tag edits are safe (their buttons call save() immediately), but free-text captions — the most effortful human metadata — are the most likely to be lost, which directly undermines the human-metadata-is-sacred invariant from the user's perspective.
- **Suggested fix:** Commit the caption on focus loss and before teardown: add a @FocusState to the caption field and call save() when it loses focus, and/or detect a dirty caption in `.task(id:)`/onDisappear and flush it before reloading. Simplest robust fix: in the `.task(id: item.hash)` closure, before calling load(), if the previously-shown item's caption differs from the local state, write it; or bind the field to a debounced save like the search box. At minimum, call save() in an onChange(of: caption) debounce so edits persist without an explicit submit.
- **Verification:** Confirmed: caption lives in local @State (line 9) persisted only via .onSubmit on a vertical-axis TextField (lines 41-44), where Return inserts a newline rather than submitting. There is no focus-loss save, no onChange debounce, and no onDisappear/dirty-check flush; navigating photos (filmstrip onTapGesture sets state.openedItem at ViewerView:187, or step() at :205) feeds a new item that re-runs .task(id: item.hash) → load() (lines 230, 398-399), silently overwriting the typed-but-unsubmitted caption. This loses human-authored metadata, though it is one optional field and recoverable by retyping, so High is at the upper edge (Medium also defensible). (Confirmed on adversarial verification.)
- **Effort:** M

### H10 — Bulk drift-repair rewrites the entire manifest once per file

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:172`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:177`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:84`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:93`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:106`, `Sources/OpenPhotoApp/AppState.swift:1255`, `Sources/OpenPhotoApp/AppState.swift:1272`, `Sources/OpenPhotoApp/AppState.swift:1179`
- **Problem:** writeManifestEntry() does Manifest.read(entire file) → mutate array → Manifest.write(entire file, sorted, atomic temp+fsync+rename) for a SINGLE entry. adopt(), restore(), and repairCorrupt() each call it once. The app drives them in per-file loops: adoptAll iterates relPaths calling adopt() per file; restoreAllRecoverable/restoreOne calls restore() per finding; repairAllRecoverable calls repairFinding→repairCorrupt/restore per finding. So 'Adopt all' / 'Restore all recoverable' / 'Repair all' on N files performs N full manifest read+rewrite cycles, each O(manifest size). For a drive with tens of thousands of entries this is quadratic disk I/O — 'Adopt all' over a freshly-copied 10k-file drive would rewrite a 10k-line manifest 10k times. DeletionPropagator.propagate, by contrast, correctly does a SINGLE manifest rewrite after the loop, showing the intended pattern.
- **Suggested fix:** Add batch variants (e.g. DriftReconciler.adopt(relPaths:), restore(findings:), repairCorrupt(findings:)) that read the manifest once, accumulate all changed/added entries in memory, and write once at the end — mirroring DeletionPropagator.propagate's 'loop then one rewrite' structure. Have adoptAll/restoreAllRecoverable/repairAllRecoverable call the batch API.
- **Verification:** Confirmed: writeManifestEntry (DriftReconciler.swift:177-180) does a full Manifest.read + sort + atomic rewrite per single entry, and adopt/restore/repairCorrupt call it once each, driven by per-file loops in adoptAll (AppState:1256), restoreAllRecoverable (1273), and repairAllRecoverable (1183) — so bulk repair of N files over an M-entry manifest is O(N*M) read+sort+fsync I/O (quadratic on a freshly-copied 10k drive). DeletionPropagator.propagate (lines 75-77) does the correct loop-then-single-rewrite, proving the intended pattern and the divergence. (Confirmed on adversarial verification.)
- **Effort:** M

### H11 — AtomicFile is not crash-durable: no F_FULLFSYNC and no parent-directory fsync after rename

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/IO/AtomicFile.swift:6`, `Sources/OpenPhotoCore/IO/AtomicFile.swift:14`, `Sources/OpenPhotoCore/IO/AtomicFile.swift:21`, `Sources/OpenPhotoCore/Sync/VerifiedCopy.swift:19`
- **Problem:** AtomicFile is the single funnel for every durable vault write (manifest.jsonl, vault.json, bin.jsonl, sidecars, registries) and its doc comment promises 'temp -> fsync -> rename' durability per format §10. Two gaps undermine that on macOS: (1) `fh.synchronize()` issues plain fsync(2), which on macOS does NOT guarantee the bytes reach stable storage across power loss — only fcntl(F_FULLFSYNC) does. (2) After `replaceItemAt` performs the rename, the containing directory is never fsync'd, so the directory entry update for the rename is not durably committed. After a crash or sudden power loss the rename can be lost or the file can read back zero-length / truncated even though write() returned success, weakening invariant 4 (all writes atomic and durable). VerifiedCopy.copy has the same plain-fsync limitation, and additionally drops the sync result with `try?` so a flush failure is invisible.
- **Suggested fix:** After writing+closing the temp file, call fcntl(fd, F_FULLFSYNC) on it (not just fsync). After the rename, open the parent directory with O_RDONLY and fsync it to durably commit the directory entry, then close it. Stop discarding the synchronize() result with `try?` in VerifiedCopy.
- **Verification:** Confirmed in code: AtomicFile.write uses fh.synchronize() (plain fsync(2), not F_FULLFSYNC) at line 14 and never fsyncs the parent directory after replaceItemAt at line 21; VerifiedCopy.copy line 19 likewise uses plain fsync and drops its result with try?. Both functions' doc comments and format §4/§10 promise temp->fsync->rename durability, and 18 call sites funnel every durable vault write (manifest, vault.json, bin.jsonl, sidecars, registries) through them, so the macOS power-loss durability gap is genuine — though the manifest's documented rebuildability somewhat mitigates the worst-case framing. (Confirmed on adversarial verification.)
- **Effort:** M

### H12 — Folder names from the UI are not sanitized for '..' — path traversal can escape the vault root

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** security
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:30`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:115`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:10`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:217`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:219`
- **Problem:** norm() only trims leading/trailing '/' and NFC-normalizes; it does not reject or strip '..' path segments. createFolder/moveFolder build absolute URLs from caller-supplied relPaths via URL.appendingPathComponent. createFolder's relPath is assembled directly from a user-typed folder name (AppState+FolderReorg.swift:217-219 take `name`, trim whitespace, and concatenate). A name like '../../Secret' (or a move target containing '..') resolves outside the vault root, letting folder creation/moves operate on arbitrary filesystem locations and write manifest entries with paths that point outside the vault. This breaks the file-sovereignty boundary and could create or relocate directories anywhere the app has access.
- **Suggested fix:** In norm(), reject any path whose components include '.' or '..' (throw ReorgError.invalidTarget), and have createFolder validate the typed name contains no path separators or traversal. Additionally assert that the resolved absolute URL still has the vault root as a prefix before any filesystem mutation.
- **Verification:** norm() (VaultReorganizer.swift:115-116) only NFC-normalizes and trims '/', and Vault.absoluteURL is a bare rootURL.appendingPathComponent with no containment check; a folder name typed into the unvalidated TextField (FolderTreeView.swift:36-40 → createFolder AppState+FolderReorg.swift:217-219 → VaultReorganizer.createFolder) like '../../Secret' standardizes to a path outside the vault root (verified empirically: /Users/jude/Vault/../../Secret → /Users/Secret), so createDirectory/moveFolder operate outside the root and manifest entries get '..' paths. Real breach of the vault-root sovereignty invariant, though it is local self-inflicted input (no remote/cross-privilege attacker), so High rather than Critical. (Confirmed on adversarial verification.)
- **Effort:** S

## Medium

### M01 — derivationTask handle can be clobbered to nil by a stale task across close/open

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** concurrency
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1461`, `Sources/OpenPhotoApp/AppState.swift:1463`, `Sources/OpenPhotoApp/AppState.swift:1466`, `Sources/OpenPhotoApp/AppState.swift:1394`, `Sources/OpenPhotoApp/AppState.swift:1473`
- **Problem:** drainDerivation captures `lib` once at entry (guard let lib = library) and only checks Task.isCancelled between items. closeLibrary does derivationTask?.cancel(); derivationTask = nil, then changeRoot/openLibrary opens a new library and calls pokeDerivation() which assigns a fresh derivationTask. The cancelled-but-still-finishing old task ends with `self?.derivationTask = nil` (line 1466), which can null out the NEW task's handle. After that, the running new drain is no longer tracked, and a later pokeDerivation will pass its `derivationTask == nil` guard and start a SECOND concurrent drain. Additionally the trailing lines of a stale drain write derivationProgress/semanticIndexDirty/facesDirty onto the new library's state (cross-library flag bleed). Because the cancelled task can also still write markDerived to the OLD captured catalog, the effect is benign for data but produces double-drains and a stuck/duplicated progress line.
- **Suggested fix:** Capture the task identity and only clear the handle if it is still the same task: `if self?.derivationTask == thisTask { self?.derivationTask = nil }` (assign the Task to a local first), and re-check `library === capturedLib` (or bail if library changed) before publishing the trailing dirty flags / progress in drainDerivation.
- **Effort:** S

### M02 — drainDerivation does per-item synchronous catalog writes and two full-table COUNT(*) queries on the main actor

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1473`, `Sources/OpenPhotoApp/AppState.swift:1502`, `Sources/OpenPhotoApp/AppState.swift:1505`, `Sources/OpenPhotoApp/AppState.swift:1507`, `Sources/OpenPhotoApp/AppState.swift:1520`
- **Problem:** drainDerivation() is @MainActor (only stage.run is detached). For every pending asset across every stage it does, on the main thread: markDerived/markDerivationFailed (a synchronous dbQueue.write) and then combinedProgress(), which runs derivationProgress() for each available stage — each a COUNT(*) over the whole assets table plus a COUNT over derivation_jobs (line 1507 calls combinedProgress per item). For a large freshly-indexed library this is thousands of synchronous DB writes + O(stages) full-table scans hopping through the main actor. await Task.yield() keeps the UI from total lockstep starvation, but it still injects heavy main-thread DB work proportional to library size during background derivation.
- **Suggested fix:** Advance the progress UI from the cheap local `progress` counter already maintained (progress.done += 1) instead of re-querying combinedProgress() every item; recompute the authoritative combinedProgress at most once per stage or on a throttle. Perform markDerived/markDerivationFailed inside the same detached task that ran the stage (passing the Sendable catalog) so the per-item DB writes don't run on @MainActor.
- **Effort:** M

### M03 — Async load/search/reverify tasks publish to @Observable state without library-identity or supersession guard (cross-library bleed / stale clobber)

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:208`, `Sources/OpenPhotoApp/AppState.swift:245`, `Sources/OpenPhotoApp/AppState.swift:476`, `Sources/OpenPhotoApp/AppState.swift:1679`, `Sources/OpenPhotoApp/AppState.swift:1379`
- **Problem:** loadPeople(), loadCullGroups(), runSearch(), and reverifySentToConnectedDevices() each capture the current `lib`, do heavy work off-main, then assign results back to observable state (self.people, self.cullGroups, self.searchResults, etc.) without re-checking that self.library is still the same object or that a newer invocation hasn't started. None of these Task handles are stored, and closeLibrary() only cancels derivationTask — so an in-flight loadPeople/runSearch survives a closeLibrary()/openLibrary() (e.g. changeRoot at line 1420) and then publishes results computed against the OLD library into the NEW library's UI. Even within one library, two rapid runSearch() calls (debounced typing) race: the slower/older one can overwrite the newer result, and `searching`/`facesLoading` can be left in the wrong state. This is the 'cross-library bleed' the audit brief calls out.
- **Suggested fix:** Capture a token/generation (e.g. refreshToken or an Int incremented in openLibrary/closeLibrary) before launching, and on the main-actor continuation bail out if the token changed or `self.library !== lib`. For search, store the Task handle and cancel the prior one before starting a new query. Consider a small helper that wraps 'detached compute then publish-if-still-current'.
- **Effort:** M

### M04 — Pervasive try? / (try? …) ?? [] swallows load failures and can render an empty UI with no error

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:100`, `Sources/OpenPhotoApp/AppState.swift:131`, `Sources/OpenPhotoApp/AppState.swift:215`, `Sources/OpenPhotoApp/AppState.swift:216`, `Sources/OpenPhotoApp/AppState.swift:269`, `Sources/OpenPhotoApp/AppState.swift:490`, `Sources/OpenPhotoApp/AppState.swift:495`, `Sources/OpenPhotoApp/AppState.swift:1025`, `Sources/OpenPhotoApp/AppState.swift:1093`
- **Problem:** Nearly every catalog read is wrapped as (try? lib.catalog.xxx()) ?? [] and most refreshes are `try? refreshQueries()`. A transient or real failure (DB locked, schema/migration error, corrupted snapshot, I/O error on a flaky drive) is silently converted to an empty array / no-op with zero user-facing signal. The user sees an empty Timeline/People/Search/Cull or stale drive state and has no indication anything failed, no way to distinguish 'no photos' from 'load failed'. videoOnly.didSet -> try? refreshQueries() (line 100) is a concrete example: toggling the filter on an error throws away the update silently. This undermines the trust model where the library is the source of truth.
- **Suggested fix:** Introduce a lightweight observable lastError / load-failed state that the views surface (banner or empty-state with retry) for the load paths the user directly observes (refreshQueries, runSearch, loadPeople, loadCullGroups). Distinguish 'genuinely empty' from 'failed' rather than collapsing both to []. Keep best-effort try? only where a failure truly is non-fatal and logged.
- **Effort:** M

### M05 — removeOpenedItem advances by flatItems, but the viewer navigates viewerItems

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1649`, `Sources/OpenPhotoApp/AppState.swift:1651`, `Sources/OpenPhotoApp/AppState.swift:1653`, `Sources/OpenPhotoApp/AppState.swift:59`, `Sources/OpenPhotoApp/AppState.swift:580`
- **Problem:** openViewer sets viewerItems as the navigation set (documented as 'the set the viewer navigates (timeline or one folder)'). But removeOpenedItem computes the next photo from flatItems (the full timeline), not viewerItems. When the viewer was opened on a folder set, or while videoOnly is filtering the timeline, deleting/evicting from the viewer either jumps to the wrong next photo or prematurely closes the viewer because the opened item isn't found in flatItems (firstIndex returns nil -> openedItem = nil). The shared keyboard-delete/inspector-delete 'keep culling without leaving the viewer' UX silently breaks for folder viewing.
- **Suggested fix:** Navigate within viewerItems, not flatItems: `if let i = viewerItems.firstIndex(where: { $0.instanceID == item.instanceID }), viewerItems.indices.contains(i + 1) { openedItem = viewerItems[i + 1] } else { openedItem = nil }`.
- **Effort:** S

### M06 — AppState is an extreme god object: one @Observable owns the entire app surface

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:51`, `Sources/OpenPhotoApp/AppState.swift:55`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:1`, `Sources/OpenPhotoApp/AppState+Undo.swift:1`
- **Problem:** A single @Observable @MainActor class (1739 lines here, ~2210 with extensions) owns library lifecycle, timeline+folder queries, search (semantic index), people/faces, cull, full drive/backup/canonical/drift/sync orchestration, presence/badges, device watching, Finder-tag sync, sidecar region writes, undo, and viewer navigation. Every SwiftUI view binds the whole object via @Bindable (35+ sites), so any mutation to any of these subsystems invalidates and can re-evaluate unrelated views — this is the structural cause of findings #1 and #2 being so costly (inspector re-renders on a drive scan, etc.). It also concentrates all mutable app state in one place, maximizing the surface for the cross-library/race issues in finding #3 and making the class hard to test in isolation.
- **Suggested fix:** Split into focused observable models behind AppState: e.g. DrivesModel (durableVaults/drift/presence/sync), PeopleModel (people/clusters/faces), SearchModel (semanticIndex/results), DerivationModel (progress/runner). Views observe only the slice they need, shrinking invalidation scope and isolating per-library state so reset/teardown is localized. This is a refactor, not a one-line fix, but it directly mitigates several other findings.
- **Effort:** L

### M07 — facesDirty and geocodeDirty are write-only dead state; People reload uses an empty-check that ignores staleness

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:199`, `Sources/OpenPhotoApp/AppState.swift:200`, `Sources/OpenPhotoApp/AppState.swift:1513`, `Sources/OpenPhotoApp/AppState.swift:1514`, `Sources/OpenPhotoApp/People/PeopleView.swift:66`
- **Problem:** facesDirty is set to true in 7 places (after every face mutation and after a derivation drain) and false in loadPeople, but it is never READ in any conditional — grep confirms no `if facesDirty`/`where facesDirty` anywhere. geocodeDirty is likewise only ever assigned (init + line 1514) and never read at all. So the carefully-maintained 'dirty' bookkeeping does nothing. Worse, PeopleView.onAppear gates the reload on `state.people.isEmpty && state.suggestedClusters.isEmpty` (PeopleView.swift:66) rather than on facesDirty — meaning that once people are loaded, returning to the People tab after new faces were derived in the background will NOT refresh the clustering, the exact case facesDirty was meant to handle. This is dead state plus a latent staleness bug.
- **Suggested fix:** Either delete geocodeDirty entirely, and have loadPeople()/PeopleView.onAppear consult facesDirty (reload when dirty even if non-empty), or remove facesDirty too and reload unconditionally on appear. Pick one mechanism rather than maintaining a flag nothing reads.
- **Effort:** S

### M08 — Inspector reads synchronous catalog + jsonl I/O on the MainActor inside view body

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1550`, `Sources/OpenPhotoApp/AppState.swift:1558`, `Sources/OpenPhotoApp/AppState.swift:1564`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:145`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:245`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:43`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift:53`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:45`
- **Problem:** locations(for:) and onlyCopyCount(_:) are called directly from SwiftUI view bodies (InspectorView.body line 145, evict-alert messages in Timeline/Folder/Inspector). Each call allocates a fresh PresenceService and, via PresenceService.locations(forHash:), runs several synchronous SQLite reads (catalog.instances, catalog.registeredVaults, catalog.vaultPresenceHashes per vault) plus SendRegistry/ImportRegistry jsonl reads — all on the MainActor. onlyCopyCount does this per hash (isOnlyOnThisMac → locations per item), so it is O(items) full presence resolutions. Because AppState is one large @Observable, the inspector re-renders on essentially any state change, re-doing this DB+file work synchronously and risking UI hitches, especially on a slow/large library or when evictableItems is big.
- **Suggested fix:** Compute presence/location data off-main (Task.detached) and cache it into observable storage (e.g. a [hash: [Location]] map) that the inspector reads as a pure lookup, refreshed on the same triggers that already call refreshQueries(). For onlyCopyCount, precompute a 'only-on-Mac' hash set once per query refresh instead of resolving per item in an alert builder. At minimum, memoize a single PresenceService instead of reallocating it (and its registry chain) on every call.
- **Verification:** Partly real: `locations(for:)` at InspectorView.swift:145 is called unconditionally in the inspector body and per render allocates a fresh PresenceService doing synchronous MainActor SQLite reads — notably `vaultPresenceHashes(forVault:)` which fetches each registered drive's entire hash Set just to test one hash — a genuine hitch risk on large libraries with drives. But the High rating rests on misreads: the heavily-emphasized O(items) `onlyCopyCount` work lives in `.alert` `message:` closures (Inspector:245, Timeline:43, Folder:53) that SwiftUI evaluates lazily only when the alert is presented (user action), not per frame, and the registries are in-memory dictionaries (no per-call jsonl reads), so the per-render cost is a single bounded item resolution — Medium. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M09 — combinedProgress() runs 10 COUNT(*) queries per item on the MainActor during derivation

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1488`, `Sources/OpenPhotoApp/AppState.swift:1507`, `Sources/OpenPhotoApp/AppState.swift:1520`, `Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift:67`
- **Problem:** drainDerivation() is an async method on the @MainActor class, so its loop body runs on the MainActor between awaits. After every single derived item it calls derivationProgress = combinedProgress(), and combinedProgress() executes catalog.derivationProgress(stage:) for each of the 5 available stages — each of which runs two COUNT(*) queries (one over the full assets table). That is up to ~10 table-scanning COUNT queries on the MainActor for every item processed across the whole library (e.g. 10k photos × multiple stages), even though the comment at line 1483 explicitly says it intends to advance a local counter to avoid a DB read per item. The local `progress` variable is incremented (line 1503) but never used to publish; the expensive combinedProgress() is published instead.
- **Suggested fix:** Publish from the cheap local counters that drainDerivation already maintains (sum the per-stage local done/total) instead of re-querying the catalog every item, or throttle combinedProgress() to run at most a few times per second. Reserve the full DB recount for stage boundaries.
- **Effort:** S

### M10 — No re-entrancy guard: overlapping reorg ops can interleave across await points

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** concurrency
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:54`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:109`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:257`, `Sources/OpenPhotoApp/Folders/FolderTreeView.swift:163-169`, `Sources/OpenPhotoApp/Folders/FolderTreeView.swift:95-99`
- **Problem:** `moveFolder`, `movePhotos`, and `deleteFolder` are @MainActor async with multiple suspension points (`Task.detached(...).value`, `await rescan()`, `await delete(...)`). Each drag-drop or context-menu action spawns an unstructured `Task { await state.moveFolder(...) }` (e.g. FolderTreeView lines 95-99, 163-169) with nothing serializing them. A user can start a second drag while the first is mid-flight (its detached drive loop or rescan suspended); the second op then reads a folderTree/selection state that the first has not finished mutating, and the two interleave their rescan/remapUIPaths/recordUndo sequences. rescan() itself guards with `!scanning` and simply early-returns (AppState.swift:1439) — so the second op's rescan can be silently skipped, leaving the UI showing stale paths after a move, and two undo records get pushed in an order that may not match what the user perceives. Although @MainActor prevents data races, the logical interleaving is an experience/correctness hazard.
- **Suggested fix:** Add a single `reorgInFlight` bool (or an async serial queue/AsyncChannel) checked at the top of moveFolder/movePhotos/deleteFolder, ignoring or queueing a second op until the first completes; or disable the drop destinations while `scanning`/a reorg is active so the UI can't enqueue overlapping ops.
- **Effort:** M

### M11 — Local catalog/presence/enqueue writes swallow errors with try?, hiding desync from the user

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:86`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:95`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:145`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:170`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:176`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:241`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:246`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:266`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:281`
- **Problem:** Drive propagation being best-effort/try? is by design (drives are passive). But the same try? is applied to *local* catalog operations whose failure is a real correctness problem: rewriteVaultPresencePaths (line 95) and rewriteVaultPresencePath (line 170) re-key the drive-presence cache after a move; enqueueFolderOp (86/145/176/241/281) is what makes offline-drive reconciliation happen at all; refreshQueries (246) is what makes the new folder appear. If any of these throw (DB locked/busy, disk full, GRDB error), the failure is silently swallowed: the Mac move already happened on disk but the offline-drive op is never queued (the move is permanently lost for that drive), or the presence cache stays keyed to the old dirPath (the documented phantom-`.missing` folder the comment at lines 91-94 is specifically trying to prevent), with no user-facing error and no rollback. The comment at line 94 says the presence rewrite "must run BEFORE rescan"; if it throws, the invariant it guards is silently broken.
- **Suggested fix:** Distinguish local from remote failures. For the local catalog writes (presence rewrites, enqueueFolderOp for offline drives, refreshQueries), do/catch and surface an alert (or at least log + set a user-visible error state) rather than try?; consider treating a failed enqueue as a propagation gap the user should know about. Keep try? only on the genuinely best-effort connected-drive disk ops.
- **Effort:** M

### M12 — Undo of a Live Photo move always shows a false "Couldn't undo" alert

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+Undo.swift:52`, `Sources/OpenPhotoApp/AppState+Undo.swift:57`, `Sources/OpenPhotoApp/AppState+Undo.swift:59`, `Sources/OpenPhotoApp/AppState+Undo.swift:67`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:122`, `Sources/OpenPhotoCore/LibraryService+Move.swift:40`, `Sources/OpenPhotoCore/Catalog/Queries.swift:88`, `Sources/OpenPhotoCore/Catalog/Queries.swift:13`
- **Problem:** When a Live Photo is moved, LibraryService.movePhotos also moves the hidden paired video and records it in result.moved (LibraryService+Move.swift:40). movePhotos (AppState) appends a MovedFileRecord for every entry in result.moved, including that video (AppState+FolderReorg.swift:122-125). On undo, .movePhotos builds inverseMoveGroups over all records and pre-flights resolution with library.catalog.items(instanceIDs:). But the paired video has isLivePairedVideo = 1 and timelineSQL filters those out (Queries.swift WHERE a.isLivePairedVideo = 0), so its instanceID `vaultID|relPath` can NEVER resolve. Each Live Photo therefore contributes a phantom unresolved count, and the user sees "Couldn't undo Move for N items / nothing was changed for those items" even though the undo fully succeeded (the photo-half carries its partner back automatically). It is a misleading-error bug that will fire on essentially every iPhone Live Photo move.
- **Suggested fix:** Exclude live-paired-video records from the unresolved pre-flight count, or count only the user-facing photo records. E.g. when building groups for the resolution check, drop ids whose underlying asset is a paired video (or compute `unresolved` only over the photo-half records), matching the fact that movePhotos resolves moves by the photo-half and carries the partner implicitly.
- **Effort:** S

### M13 — Drive propagation, offline queueing, and presence rewrites are uniformly try?-swallowed with no user signal

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:76-79`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:86`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:95`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:136-138`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:145-146`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:170-177`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:233-234`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:241`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:266-281`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:345`
- **Problem:** The error-surfacing policy is inconsistent: the Mac primary op alerts on failure (moveFolder line 62, createFolder line 224) and movePhotos aggregates file failures into one alert (lines 199-208), but every subsequent propagation step — connected-drive VaultReorganizer calls, offline `enqueueFolderOp`, `rewriteVaultPresencePaths`/`rewriteVaultPresencePath`, and `clearFolderOp` — is swallowed with `try?`/`_ = try?`. A drive whose folder move fails (e.g. destinationExists from a concurrent change), or an `enqueueFolderOp` that fails to persist (DB locked/full), leaves the Mac and that drive structurally divergent with absolutely no user-visible signal and no log. Because offline drives rely entirely on the queue, a dropped enqueue means that op is lost forever — the next connect's reconcile never replays it. This directly threatens the 'drives stay reconciled' guarantee the file header promises.
- **Suggested fix:** Distinguish 'expected stale' failures (already handled explicitly, e.g. ReorgError.missing/.notEmpty during reconcile) from unexpected ones. For the catalog writes that the design depends on (enqueueFolderOp, rewriteVaultPresencePath, clearFolderOp), capture failures and either surface an aggregate non-modal warning or at minimum os_log them so divergence is diagnosable. Keep connected-drive disk ops best-effort but record which drives failed so a later reconcile/drift scan can repair them.
- **Verification:** Confirmed in code: every post-primary step (connected-drive ops lines 76/136/233/273, offline enqueueFolderOp lines 86/145/176/241/281, presence rewrites 95/170, clearFolderOp 345) is try?-swallowed with no log; applyPendingFolderOps (only caller, AppState.swift:1216) is the sole replay path and driftScan is hash/presence-based so it cannot heal a dropped enqueue, and SyncEngine (line 150-156) confirms path-mismatch causes file duplication — so a lost enqueue genuinely diverges drives unrecoverably with no diagnostic. Downgraded to Medium because the no-user-alert behavior is an explicit design choice (file header lines 8-9, design spec) and the trigger (a single-process local GRDB write failing) is uncommon; the real, narrower defect is the missing os_log/failure record, not the absence of a modal. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M14 — people() can surface ghost zero-face person cards

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:133`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:176`, `Sources/OpenPhotoApp/People/PeopleView.swift:118`, `Sources/OpenPhotoApp/People/PeopleView.swift:261`
- **Problem:** people() does `people p LEFT JOIN faces f ... GROUP BY p.id` with no `HAVING COUNT(f.id) > 0`. A person whose faces are all moved away — e.g. reassignFace(id, to: nil) on each face, or every face reassigned to another person — keeps its `people` row with faceCount 0 and rep NULL. PeopleOverviewView renders state.people directly in a ForEach (line 118) and PersonCard shows "0 faces" (line 261), producing a ghost card with no thumbnail that the user can't easily get rid of. Only mergePerson/deletePerson delete the row; the reassign-to-nil path leaves an empty person behind with no eager cleanup.
- **Suggested fix:** Either add `HAVING COUNT(f.id) > 0` to the people() query (so empty people don't surface) or have reassignFace/assignFaces delete a person row that drops to zero faces. The query-side HAVING is the lower-risk fix and keeps the orphan row harmlessly present for re-population.
- **Effort:** S

### M15 — purgeLocalVault leaves orphaned zero-face people rows that surface as empty persons

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog.swift:246-260`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:133-152`
- **Problem:** purgeLocalVault GC's per-hash tables (assets, faces, embeddings, phash, geocode, derivation_jobs, finder_tag_sync, ocr, pending_deletions) when a hash has no remaining instance or presence. Correctly, `people` is excluded from that loop because it has no `hash` column (including it would error on the orphan WHERE clause). But the consequence is that when every face belonging to a person is deleted as an orphan, the `people` row survives with zero faces. people() does `LEFT JOIN faces ... GROUP BY p.id` with no `HAVING cnt > 0`, so it returns these as persons with faceCount 0 and representativeFaceID NULL — an empty/ghost person in the People screen after a 'switch library'/purge. coverFaceID dangling is separately handled safely by the COALESCE in people(), so only the empty-person leak is user-visible.
- **Suggested fix:** Either add `HAVING cnt > 0` (or `WHERE EXISTS (SELECT 1 FROM faces ...)`) to people() to hide faceless persons, or in purgeLocalVault delete people rows that end up with no faces: `DELETE FROM people WHERE id NOT IN (SELECT personID FROM faces WHERE personID IS NOT NULL)` after the orphan sweep. Prefer the people() filter since person rows mirror sidecar regions and can legitimately repopulate on rescan.
- **Effort:** S

### M16 — rewriteVaultPresencePaths uses a GLOB prefix that mis-handles folders containing glob metacharacters, re-introducing phantom-folder rows after a move

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog.swift:385-412`, `Sources/OpenPhotoCore/Catalog/Catalog.swift:427-451`, `Sources/OpenPhotoCore/Catalog/Queries.swift:61-84`
- **Problem:** rewriteVaultPresencePaths selects rows to re-key with `relPath GLOB (from + "/*")`. SQLite GLOB treats `*`, `?`, and `[...]` as metacharacters. If a moved folder's path contains any of these (e.g. a folder literally named `[2024]` or `Best?`), the GLOB will not match the rows under it (the `[` opens a character class; a literal `*`/`?` in the stored path won't equal the wildcard). The Swift-side `hasPrefix(from + "/")` guard only narrows the GLOB result set, it can't recover rows GLOB already excluded. The result is exactly the failure this function's doc-comment says it exists to prevent: drive-only originals keep counting under the old dirPath and the moved folder lingers as a phantom in folderCounts (and re-dragging then fails because the dir is gone on disk). The same GLOB-prefix pattern is used for browse in items(inDir:recursive:), which would under-list a subtree for such folders.
- **Suggested fix:** Either escape glob metacharacters in `from` before building the pattern (GLOB has no ESCAPE clause, so use a bracket-escaping helper: `*`→`[*]`, `?`→`[?]`, `[`→`[[]`), or switch the prefix predicate to a plain range/substring test bound as args (e.g. `relPath >= ? AND relPath < ?` with `from+"/"` and its successor, or `substr(relPath,1,len)=?`). Apply the same fix to the file-grain rewrite and items(inDir:).
- **Effort:** M

### M17 — unpackFloat16 silently returns an undersized vector on a short/corrupt blob, enabling an out-of-bounds matrix read in semantic search

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** memory
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:11-18`, `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:47-55`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:35-42`, `Sources/OpenPhotoCore/Search/SemanticIndex.swift:17-21`
- **Problem:** unpackFloat16/unpackF16 decode exactly min(dim, halves.count) Float16 elements. If a stored `vector` blob is shorter than the row's `dim` column (truncated write, partial corruption, or a dim column that overstates the blob), the returned [Float] silently has fewer than `dim` elements. SemanticIndex.init then filters rows by `$0.dim == dim`, but `dim` here is the stored COLUMN value, not the actual decoded vector length — so the short row passes the guard. `m.append(contentsOf: r.vector)` appends fewer than `dim` floats, so `matrix` ends up with fewer than count*dim elements while `query()` calls vDSP_mmul with M=count, N=dim. vDSP_mmul then reads past the end of the `matrix` backing buffer (out-of-bounds heap read / potential crash or garbage scores). The comment in SemanticIndex claims the filter prevents the out-of-bounds read, but it checks the wrong quantity.
- **Suggested fix:** Make the unpack guard the real invariant: in SemanticIndex.init filter on `$0.vector.count == dim` (the decoded length) rather than `$0.dim == dim`; and/or have unpackFloat16 pad-or-reject when halves.count < dim (return nil and let callers drop the row). Cheapest correct fix is the SemanticIndex filter change plus a `precondition(matrix.count == hashes.count * dim)`.
- **Verification:** Verified: unpackFloat16/unpackF16 decode min(dim, halves.count) and silently truncate on a short blob, and SemanticIndex.init filters on the stored COLUMN dim ($0.dim == dim, line 17) rather than the decoded vector.count, so a short row passes the guard and makes `matrix` shorter than count*dim, which vDSP_mmul (M=count, N=dim) reads past — the comment at lines 14-16 checks the wrong quantity. However, this is only reachable via a truncated/corrupt SQLite blob: the sole real writer (EmbedStage) always passes the constant dim=512 with a 512-length (or nil) vector, so no normal app/caller path can produce the divergence, and the worst case is an out-of-bounds heap READ (crash/garbage scores) against a rebuildable catalog with no user-media risk — a defensive-hardening Medium, not High. (Severity adjusted from High to Medium on verification.)
- **Effort:** S

### M18 — Face fetches always decode embedding blobs that every UI consumer discards

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:95`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:103`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:211`, `Sources/OpenPhotoApp/People/PeopleView.swift:503`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:408`, `Sources/OpenPhotoApp/AppState.swift:387`, `Sources/OpenPhotoApp/AppState.swift:411`
- **Problem:** faces(forHash:) and faces(forPerson:) SELECT the `embedding` blob + `dim` and run them through Self.unpackF16 to materialize a [Float] of dim (~128-512) elements per face inside faceRow(from:). But every display/sidecar consumer only reads id/hash/rect/confidence/personID: PeopleView.reload -> facePhotos(for:), InspectorView.loadFaces (sorts + renders chips), AppState.removePerson (uses only .hash), and writeSidecarRegions (uses .hash + .rect). None touch .embedding. For a heavily-named person with hundreds-to-thousands of faces this decodes and heap-allocates one Float array per face on every PersonDetail reload — pure wasted CPU and allocations on a path that runs on each face edit. Only the clusterer (unassignedFacesWithEmbeddings) actually needs vectors, and it already has its own query.
- **Suggested fix:** Add an embedding-free fetch variant (e.g. faceRowsLight(forHash:)/forPerson:) that omits `embedding`/`dim` from the SELECT and constructs FaceRow with an empty embedding, and point the display/sidecar call sites at it. Keep the full decode only where vectors are required.
- **Effort:** S

### M19 — CleanupView recomputes whole-collection derived arrays on every render

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:21-35`, `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:120-121`, `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:170-172`, `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:25-31`
- **Problem:** allItems (flatMap over every group's items), orderedSelectable (map building SelectableItem for every tile), selectedItems (filter over all tiles), allSuggested (nested flatMap+filter), and groupsSignature are computed properties with no memoization. SwiftUI evaluates body — and therefore each of these it references — on every state change, including each selection mutation and each rubber-band drag tick (RubberBandModifier is handed a freshly rebuilt orderedSelectable array every render). With a large tidy session (thousands of grouped tiles) this is repeated O(n) allocation/iteration per frame. tap() additionally does orderedSelectable.firstIndex(where:) — another O(n) scan — on every single tile tap. Functionally correct but a per-render scale tax exactly where the user is dragging to select many tiles.
- **Suggested fix:** Cache the derived collections: compute orderedSelectable / allItems / an instanceID->index map once when state.cullGroups changes (e.g. store on AppState alongside cullGroups, or in a @State recomputed in the existing onChange(of: groupsSignature) hook) and read them from there. Replace tap()'s firstIndex scan with a dictionary lookup.
- **Effort:** M

### M20 — loadPeople/loadCullGroups spawn uncancelled, untracked detached Tasks → stacked work and stale results

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:208`, `Sources/OpenPhotoApp/AppState.swift:212`, `Sources/OpenPhotoApp/AppState.swift:245`, `Sources/OpenPhotoApp/AppState.swift:249`, `Sources/OpenPhotoApp/AppState.swift:290`
- **Problem:** Both loaders launch a `Task { await Task.detached { ... }.value }` but never store the handle and never cancel a prior in-flight computation. loadPeople() is re-called 'when the People view appears and re-called when facesDirty after a drain'; loadCullGroups() re-runs on every cullMode change. Rapid mode/tab toggling therefore starts multiple overlapping heavy detached computations (the expensive FaceClusterer / phash dedup above) that all run to completion competing for CPU, and whichever finishes LAST overwrites `self.cullGroups`/`self.people` and clears the loading flag — a classic last-writer-wins race that can show results for the wrong mode, or flip cullLoading=false while another job is still running. Because nothing is cancellable, switching away does not stop the work.
- **Suggested fix:** Hold `private var peopleTask: Task<Void,Never>?` / `cullTask`; at the top of each loader call `task?.cancel()` then assign the new task, and check `Task.isCancelled` before assigning results back on the main actor (and inside the detached loop). This both prevents stale overwrites and lets the heavy compute abort.
- **Effort:** S

### M21 — Catalog read failures in Cull/People loaders are swallowed to empty, with no user-facing error

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:215`, `Sources/OpenPhotoApp/AppState.swift:216`, `Sources/OpenPhotoApp/AppState.swift:254`, `Sources/OpenPhotoApp/AppState.swift:259`, `Sources/OpenPhotoApp/AppState.swift:264`, `Sources/OpenPhotoApp/AppState.swift:269`
- **Problem:** Every catalog call feeding these analyzers uses `(try? ...) ?? []`: people(), unassignedFacesWithEmbeddings(), embeddingsWithTakenAt(), phashRowsWithDirPath(), items(forHashes:). A genuine failure (DB locked, corrupt blob, schema mismatch after a migration) is indistinguishable from 'no data': the user sees an empty People view or 'no duplicates found' and concludes their library is clean/empty when in fact the query threw. There is no error surfaced to AppState and no log on these particular paths (unlike nameCluster/mergePeople which at least NSLog). This is a correctness/trust problem: the cull feature could silently hide that nothing was analyzed.
- **Suggested fix:** Distinguish empty from failed: capture the error (do/catch), set a user-visible error/empty-vs-failed state on AppState, and at minimum NSLog the thrown error so a corrupt-catalog condition is diagnosable rather than presented as a clean library.
- **Effort:** S

### M22 — KeeperSelector force-unwraps max(by:) guarded only by a precondition

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Cull/KeeperSelector.swift:24`, `Sources/OpenPhotoCore/Cull/KeeperSelector.swift:37`, `Sources/OpenPhotoApp/AppState.swift:284`
- **Problem:** suggestion() does `precondition(!c.isEmpty)` then `c.max { ... }!`. `c.max(by:)` returns nil only for an empty collection, so the force-unwrap is technically dominated by the precondition — but that means the safety of a non-optional public API rests on a precondition that traps (aborts the process) in any build compiled with assertions, and on the force-unwrap itself in -Ounchecked. The caller in AppState already filters `items.count >= 2` before building `cands`, but `cands` is rebuilt independently and there is no second guard that `cands` is non-empty; any future caller (or a refactor that lets a group reach here empty) gets a hard crash rather than a recoverable nil. A pure ranking helper crashing on empty input is a sharp edge for a function whose only contract note is a doc comment.
- **Suggested fix:** Make the contract explicit and non-crashing: `guard let keep = c.max(by: ...) else { return ("", []) }` (or return an optional), dropping both the precondition and the force-unwrap. The comparator logic is unchanged.
- **Effort:** S

### M23 — Detail views run synchronous catalog DB queries on the main actor in onAppear

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoApp/People/PeopleView.swift:502-508`, `Sources/OpenPhotoApp/People/PeopleView.swift:608-613`, `Sources/OpenPhotoApp/People/PeopleView.swift:363`, `Sources/OpenPhotoApp/People/PeopleView.swift:553`
- **Problem:** PersonDetailView.reload() and ClusterDetailView.reload() are called from onAppear (and after every reassign/split) and execute catalog reads synchronously on the main actor: catalog.faces(forPerson:), catalog.people(), and in ClusterDetailView a per-faceID loop of catalog.face(forID:) (N separate queries for an N-face cluster). state.facePhotos(for:) then joins each face to its TimelineItem. For a person/cluster with hundreds of faces this is hundreds of blocking SQLite round-trips on the UI thread when the user opens the detail grid, causing a visible hitch. The People overview path correctly offloads to Task.detached (loadPeople), but these detail reloads do not.
- **Suggested fix:** Move reload()'s catalog work into a Task.detached(priority:.userInitiated) and assign pairs/allPeople back on the main actor (mirror AppState.loadPeople). Batch the per-id face(forID:) loop in ClusterDetailView into a single query that fetches all faceIDs at once.
- **Effort:** M

### M24 — FaceClusterer is O(n^2) over the full unassigned-face set, not bounded

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:43-60`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:47-49`, `Sources/OpenPhotoApp/AppState.swift:216-217`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:112-123`
- **Problem:** cluster() walks each item against every member of every existing cluster (members.contains { cosineDistance(...) }). With single-link chaining the members never collapse, so in the worst/typical case (one growing mega-cluster, which the known chaining bug actively produces) every new face is compared against all prior faces — O(n^2) cosineDistance calls, each O(dim). The doc comment justifies this as 'O(n*k) ... fine for the unassigned set (bounded and shrinking as the user names people)', but on a fresh import (e.g. the friend's real 10k-photo library acceptance test) the unassigned set IS the entire face population — tens of thousands of faces — and nothing has been named yet. unassignedFacesWithEmbeddings() returns the full WHERE personID IS NULL AND source='auto' set. This is the dominant cost behind the People view's 'Analyzing faces…' spinner and will be minutes of CPU on first run. It runs off-main (good) so it won't freeze the UI, but it is a scale wall.
- **Suggested fix:** Cap/bucket the input (e.g. blocked or LSH-bucketed candidate generation), and/or switch to a representative-vector comparison (centroid per cluster) instead of all-members single-link so per-item work is O(k) not O(cluster size). Fixing the underlying single-link chaining (use complete-link / centroid + a real face embedding) also bounds cluster growth and therefore the comparison count. At minimum, surface a progress count rather than an indeterminate spinner for large N.
- **Verification:** Confirmed: unassignedFacesWithEmbeddings() (Catalog+Faces.swift:112) returns the entire personID-IS-NULL/source='auto' set with no LIMIT, and FaceClusterer.cluster() (FaceClusterer.swift:43-60) does single-link agglomeration with members.contains{cosineDistance} and no bucketing/centroid bound, so comparison count is super-linear/quadratic in n with each call O(dim) over large feature-print vectors — a real scale wall behind the indeterminate spinner. It runs off-main (Task.detached, AppState.swift:212), produces correct output, and never crashes/corrupts/blocks the UI, so it's a performance/UX degradation rather than High; Medium is the appropriate severity (exact wall-clock depends on data distribution). (Severity adjusted from High to Medium on verification.)
- **Effort:** L

### M25 — FaceClusterer is O(n²·dim) single-link over an unbounded face set with no cancellation

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:43`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:45`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:47`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:112`, `Sources/OpenPhotoApp/AppState.swift:216`, `Sources/OpenPhotoApp/AppState.swift:217`
- **Problem:** cluster() does, for each item, `members.contains { cosineDistance(...) <= threshold }` across ALL members of ALL existing clusters, breaking on first match. The doc claims O(n·k) and 'bounded and shrinking', but the input is `unassignedFacesWithEmbeddings()` which has NO LIMIT and returns every unnamed auto face. On a fresh import (memory: friend's real 10k-photo library is the acceptance test) that is tens of thousands of face crops before the user has named anyone — k is not small, and the known single-link chaining bug actively keeps everything in ONE growing cluster, so `members.contains` scans a list that grows toward n. Each comparison is a ~2048-element Float dot product (VNGenerateImageFeaturePrint dim). Worst case is on the order of n²·dim multiplies = billions of ops, multi-minute, and it holds all vectors (n × 2048 × 4 bytes after unpack) resident. The whole thing runs in a Task.detached with no Task.checkCancellation/isCancelled, so it cannot be aborted when the user leaves the People view.
- **Suggested fix:** Cap input (LIMIT in unassignedFacesWithEmbeddings or slice the largest-N at the call site) and add `try Task.checkCancellation()` inside the outer loop. Longer term replace greedy single-link with a blocked/centroid or proper agglomerative pass (the known-bug fix) which also bounds the per-item scan. Pre-store vectors as the packed Float16 contiguous buffers to avoid the per-face array unpack.
- **Verification:** Confirmed: FaceClusterer.cluster (FaceClusterer.swift:43-60) is greedy single-link doing members.contains→cosineDistance dot-products over every member of every cluster, and its input unassignedFacesWithEmbeddings() (Catalog+Faces.swift:112) has no LIMIT, so on a fresh import the whole unnamed face set is processed at ~O(n²·dim) with no Task.checkCancellation in the detached Task (AppState.swift:212-228). Severity trimmed to Medium because it runs off the main actor (no UI freeze, no crash) and real face counts are large-but-bounded; the claim's per-comparison detail is slightly off (embeddings are unpacked once to [Float], not per-comparison, and dim is elementCount, not necessarily 2048). (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M26 — Every catalog write in the stages is try?-swallowed, so a write failure is recorded as success

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:216`, `Sources/OpenPhotoCore/Derivation/FaceStage.swift:82`, `Sources/OpenPhotoCore/Derivation/OCRStage.swift:32`, `Sources/OpenPhotoCore/Derivation/PHashStage.swift:14`, `Sources/OpenPhotoCore/Derivation/GeocodeStage.swift:36`
- **Problem:** Each stage's `run` computes the derived value, then calls `try? catalog.upsert...` / `try? catalog.replaceFaces(...)` and unconditionally `return true`. If the catalog write throws (disk full, SQLite busy/locked, migration mismatch, constraint failure), the error is discarded and `run` still returns true. The runner then calls `markDerived` (AppState.swift:1502), permanently flagging the asset as analyzed for that stage. The job is never retried, so the embedding/OCR/face/phash/geocode silently never lands for that asset — a permanent data gap with no user-facing error and no log. There is no surfaced error state anywhere in the pipeline for a derivation write failure.
- **Suggested fix:** Make the write failure propagate to the job state: change each stage to `do { try catalog.upsert...(); return true } catch { return false }` so a write failure marks the job failed and it retries (up to maxDerivationAttempts). At minimum log the swallowed error. Consider surfacing a sticky error indicator when a stage repeatedly fails its write so the user knows analysis isn't completing.
- **Effort:** S

### M27 — Derivation drain loop has no autoreleasepool around per-image Core Graphics / Vision / Core ML work across the 42k-asset run

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1489`, `Sources/OpenPhotoApp/AppState.swift:1498`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:161`, `Sources/OpenPhotoCore/Derivation/FaceStage.swift:20`, `Sources/OpenPhotoCore/Derivation/OCRStage.swift:10`, `Sources/OpenPhotoCore/Cull/PerceptualHash.swift:11`
- **Problem:** drainDerivation iterates the whole pending set per stage and, per item, runs CGImageSource decode + CVPixelBuffer/CGContext draw (EmbedStage), VNImageRequestHandler face/OCR/featureprint (FaceStage/OCRStage), and thumbnail decode (PHashStage) — all of which produce autoreleased Core Foundation / ImageIO / Vision objects. There is no `autoreleasepool` wrapping the per-item body anywhere in this loop or inside the stage `detect`/`recognizeText`/`makePixelBuffer` functions. Over a 42k-asset analysis run this is exactly the pattern that previously OOM'd indexing (per MEMORY: indexing autorelease-pool fixes). The per-item `Task.detached` does not by itself guarantee pool drainage between items. I'm flagging this at the structure level; the deep memory accounting is the memory auditor's territory.
- **Suggested fix:** Wrap the per-item work in `autoreleasepool { ... }` (the body of the `for hash in pending` loop, or inside each stage's decode/Vision entry point) so transient image buffers are released after each asset instead of accumulating until the loop's task completes. This matches the fix already applied to the indexing path.
- **Effort:** S

### M28 — GeoNames loader holds the entire 8.3 MB table as String + full substring array in RAM at once

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:23`, `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:48`, `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:49`
- **Problem:** load() reads the whole cities15000.txt into one String (8.3 MB), then `citiesText.components(separatedBy: .newlines)` materializes an array of ~33.8k String slices, and each retained line is further split by tab into per-field substrings. At peak this is the source String plus a full duplicate as the line array plus the resulting 30k City structs (six stored Strings each) — several tens of MB transiently, all on the main actor (see the eager-load finding). The resident ReverseGeocoder then keeps ~30k Cities (6 Strings each) plus the grid index alive for the whole session even if geocoding is never used.
- **Suggested fix:** Stream the file line-by-line instead of components() (e.g. read Data and iterate over newline ranges, or use a buffered line reader) so peak transient memory is bounded by one line, not the whole file twice. Combined with lazy off-main loading this removes both the launch stall and the memory spike. Consider deduplicating repeated region/country Strings (intern via a small dictionary) to shrink the resident footprint of 30k Cities.
- **Effort:** M

### M29 — GeoNames table loads eagerly on the main actor during AppState construction, blocking launch

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1456`, `Sources/OpenPhotoApp/AppState.swift:1457`, `Sources/OpenPhotoCore/Derivation/GeocodeStage.swift:15`, `Sources/OpenPhotoCore/Derivation/GeocodeStage.swift:18`, `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:20`, `Sources/OpenPhotoApp/OpenPhotoApp.swift:7`
- **Problem:** `derivationStages` is a stored property with an inline initializer that calls `GeocodeStage()` (line 1457). GeocodeStage's convenience init synchronously calls `GeoNamesLoader.load`, which does `String(contentsOf: cities15000.txt)` (8.3 MB) and `components(separatedBy: .newlines)` over ~33,817 lines, building 30k City structs plus admin1/country dictionaries — all before the initializer returns. Because AppState is `@Observable @MainActor` and is created at `@State private var state = AppState()` (OpenPhotoApp.swift:7), this whole parse runs on the main actor at app-launch time, stalling first paint by the full parse cost regardless of whether the user ever uses geocoding. The registry is intended to be cheap/idempotent but this one element is neither.
- **Suggested fix:** Make the geocoder load lazy and off-main: either build the derivationStages array lazily after the window appears, or give GeocodeStage a lazy/async backing loader (load the table inside the detached drain on first use, or in a `Task.detached(.utility)` kicked from library-open) instead of in the synchronous initializer. Keep `isAvailable` answerable cheaply (file-existence check) without forcing the full parse, mirroring EmbedStage.isAvailable.
- **Verification:** Confirmed: AppState is @Observable @MainActor (line 51-52) and is built at app launch via @State AppState() (OpenPhotoApp.swift:7); its `derivationStages` is a `let` with an inline initializer that synchronously runs GeocodeStage()'s convenience init, which calls GeoNamesLoader.load to read the bundled 8.3 MB / 33,817-line cities15000.txt and build ~30k City structs before init returns — all on the main actor, unconditionally, with isAvailable checked only later. It is a real avoidable launch-time main-actor stall, but the cost is a one-time ~tens-to-hundreds-ms file-cached parse, so the failure mode is a perceptible hitch rather than a multi-second block; severity is Medium, not High. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M30 — Semantic-search query path reconstructs EmbedStage per query, recompiling the text Core ML model each time

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:510`, `Sources/OpenPhotoApp/AppState.swift:503`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:67`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:95`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:104`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:115`
- **Problem:** EmbedStage memoizes model loads PER INSTANCE (triedTextLoad/textModel fields). The query path at AppState.swift:510 constructs a brand-new `EmbedStage()` for every semantic search and calls `embedText(q)`, which triggers `loadTextModel()` -> `MLModel.compileModel(at:)` + `MLModel(contentsOf:)` + `CLIPTokenizer(vocabDirectory:)` (read+gunzip+parse the 49k-entry vocab) on that fresh instance. So each search recompiles the text encoder and reparses the BPE vocab from scratch — hundreds of ms to seconds of avoidable latency on the search hot path, and repeated work the lazy-cache was designed to avoid. The runner's shared EmbedStage instance (AppState.swift:1456) is unaffected because it's the image encoder, but the query path defeats the memoization entirely.
- **Suggested fix:** Hold a single long-lived EmbedStage (e.g. reuse the one already in `derivationStages`, or store a dedicated `private let embedder = EmbedStage()` on AppState) and call `embedText` on that shared instance from the query path, so the text model + tokenizer compile once and stay resident. The NSLock guard already makes the instance safe to share across the detached search Task and the runner.
- **Effort:** S

### M31 — Repair/drift sheets are re-entrant: long async repair leaves trigger buttons live with no progress

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift:28`, `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift:88`, `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift:121`, `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift:114`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:114`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:125`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:86`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:98`
- **Problem:** In ConsensusRepairSheet, repairEverything() and repairOne() are launched from buttons but never set `running = true`, so the 'Repair all (N)' button and every per-row 'Repair' button stay enabled and show no spinner while the (potentially minutes-long, file-copying) repair runs. The user can click 'Repair all' twice, launching two concurrent passes over the same drives (repairAllRecoverable → repairFinding does file copies/moves into the drive bin with no internal in-flight guard). DriftReviewSheet has the same shape: the corrupt-section 'Repair'/'Repair all' and missing-section 'Restore'/'Restore all' kick off `Task { ... }` without disabling themselves or clearing `report`, so they remain tappable and re-fireable during the operation. Concurrent repairs of the same finding race on the same destination relPath.
- **Suggested fix:** Add a `@State private var repairing = false` (or reuse `running`) set true at the start of repairEverything/repairOne and the DriftReviewSheet repair/restore Tasks, `.disabled(repairing)` the buttons, reset in a `defer`, and surface a small ProgressView. This both prevents the double-launch race and gives the user feedback.
- **Effort:** M

### M32 — Failed device enumeration is swallowed and presented as a successful empty grid

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:330`, `Sources/OpenPhotoApp/Devices/ImportView.swift:332`, `Sources/OpenPhotoApp/Devices/ImportView.swift:326`, `Sources/OpenPhotoApp/Devices/ImportView.swift:327`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:105`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:190`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:199`
- **Problem:** ImportView.reloadItems() does `items = (try? await source.enumerateItems()) ?? []` and connect() then unconditionally sets `phase = .ready`. enumerateItems() can throw on a real failure (camera disconnect mid-enumeration, permission/IO error, a corrupt foreign vault). When it does, the thrown error is discarded, `items` becomes empty, and the UI shows a fully 'ready' import screen with zero items and no error message — indistinguishable from a genuinely empty device. The user cannot tell a transient/connection failure from an empty card and has no retry affordance. The same swallow pattern repeats in FreeUpPhoneView's .task and after each delete/empty-trash, where a failed re-enumeration silently empties the live list (potentially hiding items that are still on the device).
- **Suggested fix:** Capture the error from enumerateItems(): on throw in connect(), set `phase = .failedToConnect(String(describing: error))` instead of falling through to `.ready`. In FreeUpPhoneView keep the previous liveItems on a failed re-enumeration (or surface a small inline error) rather than replacing with `[]`.
- **Effort:** S

### M33 — Derived collections recomputed O(n) several times per render in ImportView and FreeUpPhoneView

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:30`, `Sources/OpenPhotoApp/Devices/ImportView.swift:230`, `Sources/OpenPhotoApp/Devices/ImportView.swift:269`, `Sources/OpenPhotoApp/Devices/ImportView.swift:137`, `Sources/OpenPhotoApp/Devices/ImportView.swift:155`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:25`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:32`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:35`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:65`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:68`
- **Problem:** ImportView.displayItems filters all `items` on every access (and for foreign vaults additionally does an O(folders) hasPrefix scan per item), and it is read multiple times per body pass: ForEach (line 137), orderedSelectable for the RubberBandModifier (line 155, which maps displayItems again), and selectedDisplayCount (line 269, used twice in the footer). FreeUpPhoneView.verifiedOnDevice re-filters liveItems through the registry lock on every access, and thisSession/previous (each re-deriving verifiedOnDevice) are read ~5 times in one body render (lines 65,66,68,69,70). None of these are memoized, so a large device causes repeated O(n) (or O(n*folders)) work on every SwiftUI invalidation.
- **Suggested fix:** Compute the filtered list once and store it: recompute displayItems / verifiedOnDevice into @State only when their inputs change (items, checkedFolders, liveItems, selection), or hoist the filter result into a single `let` at the top of body and pass it down. At minimum, derive orderedSelectable from the already-computed displayItems instead of re-mapping, and compute thisSession/previous once per render.
- **Effort:** M

### M34 — DeviceWatcher.volumesChanged does synchronous Vault.open + fileExists on the MainActor for every removable volume on each mount/unmount

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:159`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:170`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:177`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:84`, `Sources/OpenPhotoCore/Vault/Vault.swift:42`
- **Problem:** volumesChanged() is @MainActor (DeviceWatcher is @MainActor) and is invoked from the NSWorkspace didMount/didUnmount notifications and from start(). For every mounted removable volume it calls Vault.open(at:) — which does Data(contentsOf: .openphoto/vault.json) + JSONDecoder synchronously — and FileManager.fileExists for DCIM. These are synchronous disk reads on the main thread; a spinning external HDD, an SD card, or a slow/sleeping volume can stall the UI on every plug/unplug event.
- **Suggested fix:** Do the per-volume probing (Vault.open, DCIM fileExists, resourceValues) on a background task and hop back to the main actor only to assign `devices`. Debounce rapid mount/unmount bursts so a multi-partition drive doesn't trigger several full rescans.
- **Effort:** M

### M35 — DrivesView render and onChange paths run synchronous filesystem I/O and catalog queries per drive

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Drives/DrivesView.swift:115`, `Sources/OpenPhotoApp/Drives/DrivesView.swift:121`, `Sources/OpenPhotoApp/Drives/DrivesView.swift:185`, `Sources/OpenPhotoApp/Drives/DrivesView.swift:72`, `Sources/OpenPhotoApp/Drives/DrivesView.swift:87`, `Sources/OpenPhotoApp/AppState.swift:829`, `Sources/OpenPhotoApp/AppState.swift:835`, `Sources/OpenPhotoApp/AppState.swift:996`
- **Problem:** row(vr) calls state.driveIsPresent(vr) and state.driveFolderExists(vr) (each a synchronous FileManager.fileExists/stat) for every drive on every List render, and statusText adds another. Worse, .onChange(of: state.adoptableDrive?.id) and .onChange(of: state.conflictingCanonical?.id) force SwiftUI to evaluate the `adoptableDrive` computed property on each re-render; that property iterates durableVaults doing fileExists + a catalog query (vaultPresenceHashes) per drive. AppState's own comment on driveKind explicitly avoids live FS I/O on the render path for exactly this reason (slow/offline network share could hang), but driveIsPresent/driveFolderExists/adoptableDrive were not given the same treatment.
- **Suggested fix:** Cache presence/adoptability the same way driveKind is cached (refresh on connect/scan/mount events) so the render path is a pure dictionary lookup, and avoid recomputing adoptableDrive on every render by storing it as state updated when the drive set changes rather than as a derived computed read by onChange.
- **Effort:** M

### M36 — ImportView rebuilds in-library/imported/sent caches with synchronous full-table catalog scans on the MainActor

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:344`, `Sources/OpenPhotoApp/Devices/ImportView.swift:364`, `Sources/OpenPhotoApp/Devices/ImportView.swift:365`, `Sources/OpenPhotoApp/Devices/ImportView.swift:372`, `Sources/OpenPhotoApp/Devices/ImportView.swift:330`, `Sources/OpenPhotoApp/Devices/ImportView.swift:394`, `Sources/OpenPhotoCore/Catalog/Queries.swift:46`, `Sources/OpenPhotoCore/Catalog/Queries.swift:196`
- **Problem:** rebuildImportedCache / rebuildInLibraryCache / rebuildSentCache are plain (non-async) functions on the @MainActor View and are called directly from reloadItems() and runBatch(). rebuildInLibraryCache calls state.library?.catalog.knownSizeDateKeys() (a full scan of the timeline view, building a Set of every 'size|second' key in the library) and catalog.assetHashes() (SELECT hash FROM assets — every hash in the catalog) synchronously on the main actor. rebuildImportedCache iterates every device item and hits the registry lock per item. For the stated acceptance test (a friend's real ~10k import against an existing large library) this blocks the UI thread on every reload and after every batch import, on top of the per-item loops over `items`.
- **Suggested fix:** Move the catalog queries off the main actor: fetch knownSizeDateKeys()/assetHashes() once via Task.detached (or an async catalog accessor) and pass the resulting Sets into the pure matching loops; only assign the @State Sets back on the MainActor. Cache the two library-wide Sets for the lifetime of the sheet instead of refetching them in each rebuild call.
- **Verification:** Confirmed: rebuildInLibraryCache/rebuildImportedCache/rebuildSentCache are plain non-async methods on the @MainActor ImportView, called directly from async reloadItems() and runBatch() with no actor hop; knownSizeDateKeys() and assetHashes() each run a synchronous blocking GRDB dbQueue.read full-table scan (entire timeline union / SELECT hash FROM assets) on the main thread, refetched on every reload and after every batch, plus a per-item NSLock in the registry loop. Real main-thread blocking, but it is localized to the import modal and triggered at discrete user events on bounded, index-simple queries, so Medium is the more defensible severity than High. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M37 — Cluster sheet shows the previous cluster's photos and a mismatched count until the async query returns

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:190-197`, `Sources/OpenPhotoApp/Map/MapView.swift:202-263`, `Sources/OpenPhotoApp/Map/MapView.swift:55-57`
- **Problem:** openClusterSheet sets selectedCluster (which presents the sheet via .sheet(item:)) and THEN kicks off an async catalog fetch into sheetItems, but never clears sheetItems first. The sheet body renders 'cluster.count photos here' from the freshly-selected cluster while the grid still shows the prior cluster's sheetItems (or, on first open, an empty grid is handled, but on the second open stale items flash). There is also no guard that the async result belongs to the still-selected cluster, so a fast reopen can race and populate the grid with the wrong cluster's photos.
- **Suggested fix:** In openClusterSheet set sheetItems = [] before presenting, and capture the cluster id; after the await, assign only if selectedCluster?.id still matches the captured id (drop a stale result). Alternatively drive the grid off a per-cluster .task(id: cluster.id) inside clusterSheet so SwiftUI cancels/reloads correctly.
- **Effort:** S

### M38 — Map clusters get a fresh UUID every recompute, destroying annotation identity on every pan/zoom

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:377`, `Sources/OpenPhotoApp/Map/MapView.swift:64`, `Sources/OpenPhotoApp/Map/MapView.swift:13`
- **Problem:** MapCluster.id is a UUID assigned with UUID() inside cluster(...) (line 377), which runs on every onMapCameraChange (debounced recluster) and on load. Because ForEach(clusters) keys on that id, every recluster produces an entirely new identity set even when the same photos remain clustered at the same spot. SwiftUI/MapKit therefore tears down and recreates ALL Annotation views on every camera change, re-running each pin's ThumbnailImage .task and re-decoding thumbnails. This causes visible pin flicker and unnecessary thumbnail churn during pan/zoom, scaling with cluster count.
- **Suggested fix:** Derive a stable id from cluster content instead of a random UUID — e.g. id = representativeHash, or a hash of the sorted member hashes, or the bucket key (la,lo). Identical buckets across reclusters then keep their identity and MapKit diffs in place rather than rebuilding everything.
- **Effort:** S

### M39 — People overview never refreshes when faces change in the background (facesDirty ignored by the view)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/People/PeopleView.swift:65-69`, `Sources/OpenPhotoApp/AppState.swift:199`, `Sources/OpenPhotoApp/AppState.swift:1513`, `Sources/OpenPhotoApp/AppState.swift:208-229`
- **Problem:** PeopleOverviewView.onAppear calls state.loadPeople() ONLY when both state.people and state.suggestedClusters are empty. AppState sets facesDirty = true after a derivation drain (AppState.swift:1513) to signal that clustering should be recomputed, but facesDirty is private and nothing in the view re-reads it. So once the overview has shown any people/clusters, returning to the People tab after newly-detected faces have drained will NOT recluster or pick up new suggested groups — the user sees stale data until the lists somehow empty. The documented intent ('re-called when facesDirty after a drain') is not wired into the view.
- **Suggested fix:** Expose facesDirty (or a public refresh token) and have PeopleOverviewView reload when it is set, e.g. .onAppear { if facesDirty { loadPeople() } } or .task(id: state.facesRefreshToken) { loadPeople() }. Bump a token in AppState wherever facesDirty is set so the view recomputes on next appearance.
- **Effort:** S

### M40 — People detail/cluster reload runs per-face synchronous DB queries on the main actor

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/People/PeopleView.swift:502`, `Sources/OpenPhotoApp/People/PeopleView.swift:503`, `Sources/OpenPhotoApp/People/PeopleView.swift:504`, `Sources/OpenPhotoApp/People/PeopleView.swift:505`, `Sources/OpenPhotoApp/People/PeopleView.swift:608`, `Sources/OpenPhotoApp/People/PeopleView.swift:612`, `Sources/OpenPhotoApp/AppState.swift:594`
- **Problem:** PersonDetailView.reload() and ClusterDetailView.reload() are synchronous functions invoked from .onAppear on the @MainActor. Each does blocking SQLite I/O on the main thread: faces(forPerson:)/face(forID:) (1 query), people() (an aggregating GROUP BY query), and then state.facePhotos(for:) which calls lib.item(hash:) once PER face (N separate DB round-trips). For a person who appears in hundreds or thousands of photos this performs hundreds/thousands of synchronous queries on the main thread on every appearance and after every reassign/split/remove (each handler calls reload() again), freezing the UI. Unlike loadPeople()/loadCullGroups() — which deliberately hop off-main via Task.detached — these reload paths run entirely on the main actor.
- **Suggested fix:** Make reload() async and move the catalog work into a Task.detached(priority:.userInitiated) that returns the resolved [FacePhoto]/[PersonRow], then assign to @State on the main actor. Better, replace the per-face item(hash:) loop in facePhotos with a single batched query (e.g. items(forHashes:) keyed back to faces) so it is one round-trip instead of N.
- **Verification:** Both PersonDetailView and ClusterDetailView are SwiftUI View structs (implicitly @MainActor); their synchronous reload() (PeopleView.swift:502-508, 608-613), called from .onAppear and from every reassign/split/remove handler, runs blocking GRDB dbQueue.read queries on the main thread — faces(forPerson:)/face(forID:), the aggregating GROUP BY people(), and facePhotos(for:) which issues item(hash:) once per face (AppState.swift:594-599), exactly the off-main pattern that loadPeople()/loadCullGroups() use Task.detached to avoid. Defect is real but its scope is localized to People detail/cluster navigation and scales with one person's photo count (individual local-SQLite reads are sub-ms), so it stutters/hangs rather than the library-wide freeze implied by High — Medium is more accurate. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M41 — Cluster sheet shows stale items from the previously opened cluster

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:190`, `Sources/OpenPhotoApp/Map/MapView.swift:42`, `Sources/OpenPhotoApp/Map/MapView.swift:223`
- **Problem:** openClusterSheet sets selectedCluster = cluster (which presents the sheet immediately) and then fetches sheetItems asynchronously, but never resets sheetItems first. sheetItems is also never cleared when the sheet closes (selectedCluster = nil). Consequences: (1) opening a second cluster briefly renders the FIRST cluster's photos in the grid under the new cluster's header/count until the async query completes; (2) if the new fetch returns empty, the previous cluster's items persist and are shown as if they belong to the new cluster. The header count comes from cluster.count while the grid comes from stale sheetItems, so they can disagree.
- **Suggested fix:** Set sheetItems = [] at the top of openClusterSheet (before presenting / before the await) so the sheet shows the ProgressView placeholder until the correct items load, and optionally clear it on dismiss. Guard the async assignment with a check that selectedCluster is still this cluster before assigning.
- **Effort:** S

### M42 — state.library! force-unwraps crash if the library is torn down while a grid/sheet is visible

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Folders/FolderGridView.swift:125`, `Sources/OpenPhotoApp/Map/MapView.swift:241`, `Sources/OpenPhotoApp/People/PeopleView.swift:640`
- **Problem:** Three tile builders force-unwrap state.library! while constructing ThumbnailImage. AppState.closeLibrary() (AppState.swift:1382) sets library = nil at runtime. closeLibrary resets selectedFolder = nil (which makes FolderGridView fall back to ContentUnavailableView, so the Folders site is largely protected), but it does NOT reset MapView.sheetItems, MapView.clusters, or PersonDetailView/ClusterDetailView pairs — those are view-local @State. If a re-render occurs with non-empty local state after library becomes nil (e.g. a cluster sheet open, or the People grid still mounted during teardown), the force-unwrap traps and crashes. The window is narrow but reachable via the close-library / switch-root flow.
- **Suggested fix:** Replace the force-unwraps with a guarded path: build the tile only `if let lib = state.library`, otherwise render the placeholder (Theme.tile), mirroring how thumbnailBubble already does `if let lib = state.library`. Alternatively have closeLibrary() also clear the dependent view state, but a local guard is the robust fix.
- **Effort:** S

### M43 — FaceCropView crops on the main actor and caches nothing, repeating fetch+crop per card on every scroll

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/People/PeopleView.swift:705-812`, `Sources/OpenPhotoApp/People/PeopleView.swift:740-741`, `Sources/OpenPhotoApp/People/PeopleView.swift:787-810`, `Sources/OpenPhotoApp/People/PeopleView.swift:715`
- **Problem:** loadCrop() is annotated @MainActor; only the thumbnail FETCH is detached. After the await, the CGImage crop math (thumb.cropping(to:) plus the intersection/flip arithmetic, lines 789-810) executes back on the MainActor for every face. FaceCropView also keeps only an in-view @State croppedImage and has no shared cache (unlike ThumbnailImage's tileMemoryCache), so each time a PersonCard/ClusterCard/face thumbnail scrolls offscreen and back, the whole fetch+crop runs again keyed by cacheID. On a People overview or person detail with hundreds of faces this is repeated main-thread cropping that will hitch scrolling, and it re-decodes/re-crops work that never gets memoized.
- **Suggested fix:** Do the cropping inside the detached task (cropping is pure CGImage work and needs no main-actor isolation), assigning only the final CGImage on main. Add a small shared NSCache keyed by cacheID for cropped face images (mirroring tileMemoryCache) so revisited cards render synchronously without re-cropping.
- **Verification:** Verified: loadCrop() is @MainActor (PeopleView.swift:740); only the thumbnail fetch is detached (764-783) while the crop arithmetic and thumb.cropping(to:) (789-810) run back on the main actor, and FaceCropView stores results only in @State croppedImage (715) with no shared cache, unlike ThumbnailImage's tileMemoryCache. Used inside LazyVGrid/ForEach (117-153, 368-534), so every scroll-back re-runs the detached task, the catalog face(forID:) lookup, and the main-actor crop. Real and unmemoized; downgraded to Medium because cachedDisplayImage already avoids re-decoding the thumbnail and cropping(to:) is lazy, so the repeated cost is modest rather than a full re-decode. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M44 — onMapCameraChange reclusters during programmatic fit/zoom animations, and loadAssets' recluster can race the debounced one

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:75-79`, `Sources/OpenPhotoApp/Map/MapView.swift:166-188`, `Sources/OpenPhotoApp/Map/MapView.swift:287-298`, `Sources/OpenPhotoApp/Map/MapView.swift:337-343`
- **Problem:** fitMapToAssets and zoomIntoCluster drive mapPosition programmatically inside withAnimation; every intermediate camera frame fires onMapCameraChange, which calls scheduleRecluster repeatedly during the 0.5s animation. Combined with the fresh-UUID rebuild above, this causes a burst of reclustering and annotation churn precisely when the map is animating. Separately, loadAssets calls recluster(region:) (un-debounced, hops to MainActor) right before fitMapToAssets triggers more camera-change reclusters, so two clustering paths run for the same initial load with no cancellation between them.
- **Suggested fix:** Suppress reclustering while a programmatic animation is in flight (a flag set around withAnimation, cleared after the duration), and rely solely on the debounced scheduleRecluster for user-driven pans. Drop the standalone recluster(region:) in loadAssets and let the post-fit camera change drive the first cluster pass, or share one cancellable task.
- **Effort:** M

### M45 — Dictionary(uniqueKeysWithValues:) traps on duplicate ids/paths (Live-pair expansion and verify map)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/ImportEngine.swift:52`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:145`
- **Problem:** Both Dictionary(uniqueKeysWithValues:) calls crash (fatalError) if any key repeats. Line 52 builds byID from source.enumerateItems() keyed on item.id; line 145 builds manifestByPath keyed on manifest entry.path. Today ids/paths happen to be unique per source, but enumerateItems() is source-supplied and uncontrolled here, and a corrupted or hand-edited manifest.jsonl with a duplicated path line would take down the entire import with an uncatchable trap (it's not inside a do/catch and Dictionary's precondition failure isn't a throwable error). A duplicate-id ImportSource is a plausible future foot-gun (e.g. a source whose stable id derivation collides).
- **Suggested fix:** Use the merging initializer: Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) at line 52 and the same for manifestByPath at line 145. Last/first-wins is fine here since both are lookup maps; this turns a hard crash into defined behavior.
- **Effort:** S

### M46 — Free-up-phone deletion eligibility uses a metadata fingerprint, not the content hash — collision can delete an un-imported original

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:25`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:28`, `Sources/OpenPhotoCore/Import/ImportRegistry.swift:25`, `Sources/OpenPhotoCore/Import/ImportRegistry.swift:55`, `Sources/OpenPhotoCore/Import/CameraSource.swift:218`
- **Problem:** FreeUpPhoneView.verifiedOnDevice decides which on-device photos are safe to delete purely from registry.contains(sourceKey,name,size,takenAt). The registry key (ImportRegistry.Entry.key / contains) is sourceKey|name|size|takenAt — a metadata fingerprint, never the file's content hash. The on-device file is never hashed before deletion. If two DISTINCT photos on the same device share name + byteSize + the same takenAt timestamp (common: cameras reuse IMG_0001 after counter resets; burst/edited frames can match size; creationDate is frequently second-precision so the millis string collides), importing photo A records an entry that makes photo B read as 'verified imported'. The user can then permanently delete B from the phone via requestDeleteFiles even though B's bytes were never copied into the library — an irreversible loss of the only original. The engine's own skip logic correctly uses the exact content hash (hashPresent), so this weaker fingerprint is only in the delete/badge path.
- **Suggested fix:** Gate delete-eligibility on content, not metadata. Before listing an item as deletable, hash the on-device file (the engine already downloads to verify on import; for free-up, fetch+hash the candidate or persist the per-device file's hash at import time and compare). At minimum, require that registry.entries(forHash:) for the device's actual bytes exists, rather than trusting name|size|takenAt. If hashing every device file is too costly, narrow the window by also comparing against the catalog hash of the placed copy keyed by this exact source item.
- **Verification:** Confirmed in code: FreeUpPhoneView.verifiedOnDevice (lines 25-31) gates irreversible on-device deletion solely on registry.contains, whose key (ImportRegistry.Entry.key, line 25) is sourceKey|name|size|takenAt with no content hash, and CameraSource.delete (line 245) never hashes the device file — while ImportEngine stores and uses the real hash in the skip path (lines 93-100), so the weaker fingerprint is only on the delete path. The defect is real but the failure requires two distinct files on the same device to coincide in name AND byteSize AND takenAt-to-millis, an uncommon collision, so High is somewhat inflated — Medium. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M47 — EmbeddedMetadata.embed deletes the staged original before the move and the fetch swallows failure with try?

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift:70`, `Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift:71`, `Sources/OpenPhotoCore/Import/TakeoutSource.swift:76`, `Sources/OpenPhotoCore/Import/VolumeSource.swift:133`, `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:93`
- **Problem:** embed() does `removeItem(at: url)` then `moveItem(tmp -> url)` (not a replaceItemAt). If moveItem throws after the original was removed, the staged file is destroyed. All three call sites (TakeoutSource/VolumeSource/PhotosLibrarySource fetch) invoke embed via `try?`, so the error is silently swallowed and fetch returns as if successful. The vault is NOT corrupted (this is in staging, and ImportEngine line 89 then ContentHash.ofFile throws on the missing file → item is failed cleanly at line 106), so no half-file reaches the library. But the failure is invisible to the user, surfacing only as a generic 'failed' with a file-not-found reason, and the embed step is non-atomic where every other vault write in the codebase goes through AtomicFile/replaceItemAt.
- **Suggested fix:** Make embed atomic: write tmp then `try FileManager.default.replaceItemAt(url, withItemAt: tmp)` instead of remove+move so a failed write never destroys the source. Separately, consider not swallowing embed errors with try? — at least log them — so a systematically failing metadata fold (e.g. unwritable HEIC) is diagnosable rather than presenting as mysterious per-file import failures.
- **Effort:** S

### M48 — displayItems recomputed many times per render; O(n×folders) for foreign vaults

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:230-237`, `Sources/OpenPhotoApp/Devices/ImportView.swift:30-32`, `Sources/OpenPhotoApp/Devices/ImportView.swift:269-271`, `Sources/OpenPhotoApp/Devices/ImportView.swift:137`, `Sources/OpenPhotoApp/Devices/ImportView.swift:70-71`
- **Problem:** `displayItems` is a stored-nowhere computed property that filters the entire `items` array on every access. For a foreign vault it additionally runs `checkedFolders.contains { dir == $0 || dir.hasPrefix($0+"/") }` per item — O(items × checkedFolders). It is evaluated repeatedly per `body` pass: directly in `importGrid`'s ForEach, transitively via `orderedSelectable` (used by the grid AND the RubberBandModifier), via `selectedDisplayCount` (referenced twice in `footer`), and the analogous full-`items` filter in the header's "Select all new". The design docs explicitly target 10k-item foreign drives, and rubber-band drag re-evaluates `orderedSelectable`/`displayItems` continuously while dragging. This turns each render and each drag tick into multiple full-array (and for foreign, quadratic) passes.
- **Suggested fix:** Compute the display/selectable lists once when inputs change (in `reloadItems()` / on `checkedFolders` or `selection` change) and store them in `@State`, rather than recomputing inside `body`-reachable computed properties. For foreign filtering, precompute a Set of allowed dir-prefixes or index items by dirPath so membership is O(1) instead of scanning `checkedFolders` per item.
- **Effort:** M

### M49 — rebuildInLibraryCache / rebuildImportedCache do non-scaling catalog+registry work

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:364-379`, `Sources/OpenPhotoApp/Devices/ImportView.swift:344-358`, `Sources/OpenPhotoCore/Catalog/Queries.swift:46-55`, `Sources/OpenPhotoCore/Catalog/Queries.swift:196-200`, `Sources/OpenPhotoCore/Import/ImportRegistry.swift:55-58`
- **Problem:** These rebuilds run synchronously on the MainActor at connect time and after every batch. `rebuildInLibraryCache` calls `catalog.knownSizeDateKeys()` (a full SELECT over the entire timeline union, building a Set of every catalogued asset) and, when any item carries a knownHash, `catalog.assetHashes()` (a full `SELECT hash FROM assets` into a Set) — both materialize the whole library in memory on the main thread. `rebuildImportedCache` then does a per-item `registry.contains(...)` call, each taking the registry NSLock and building a key string, i.e. O(items) lock round-trips. For a large library + large source this is a noticeable main-thread stall on connect and after each import batch.
- **Suggested fix:** Move the catalog reads off the MainActor (await a background task that returns the Sets, then assign on main). Fetch `knownSizeDateKeys`/`assetHashes` once per connect rather than per rebuild, and expose a bulk membership API on ImportRegistry (snapshot its key set under one lock) instead of N locked `contains` calls.
- **Effort:** M

### M50 — Finder-tag baseline persisted even when the xattr writes it represents failed

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:243-257`, `Sources/OpenPhotoCore/Interop/FinderTags.swift:11-15`
- **Problem:** reconcileFinderTags computes the merged tag set, writes it to every local file with `try? FinderTags.write` (failures silently swallowed, line 254), then unconditionally stores the merged set as the new baseline with `try? catalog.setFinderTagBaseline` (line 255). If a write fails on one or more files (permission, read-only volume, locked file), the on-disk Finder tags no longer match the saved baseline. Because the next 3-way TagMerge derives removed/added relative to that baseline, the divergence is misattributed on a later pass: a tag the user actually still has on disk can be computed as removed (and then deleted from the catalog/sidecar), or vice-versa. The merge logic itself is correct; the bug is updating the baseline as if the writes succeeded.
- **Suggested fix:** Only advance the stored baseline after confirming the writes succeeded on all reachable files (collect write results; if any failed, skip setFinderTagBaseline so the next pass re-derives against the prior baseline). Surface or log persistent write failures instead of dropping them.
- **Effort:** S

### M51 — Sidecar-to-catalog ingest cannot clear metadata when a sidecar becomes empty

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:70-80`
- **Problem:** ingestSidecars guards `data != .empty else { continue }`, so when a sidecar is deleted or edited externally down to no metadata, the asset's catalog columns (favorite/rating/caption/tagsJSON) are never reset and retain stale prior values indefinitely. The method's own doc-comment asserts sidecars are authoritative, but this path cannot move a value back to the empty/default state — only non-empty edits propagate. Divergence is observable after any external sidecar edit + rescan (e.g. Lightroom clears a rating, or the user deletes the .xmp).
- **Suggested fix:** Iterate manifest entries and write the parsed SidecarData unconditionally (including .empty -> reset columns to defaults) rather than skipping empties, OR explicitly clear catalog human-metadata for assets whose sidecar is absent/empty during ingest. Keep the corrupt-sidecar skip (try? parse failure) separate from the legitimately-empty case.
- **Effort:** M

### M52 — delete() batch aborts mid-loop on a single enqueue failure, leaving disk/catalog inconsistent

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:303-325`
- **Problem:** Inside the per-item loop, moveToBin failures are caught and skipped (good), but `enqueuePendingDeletion` (line 311) is a bare `try`. If it throws after a successful moveToBin, the whole function throws: the file is already in the bin, `n` was not incremented for it, the per-vault rescan at line 322 never runs, and any remaining vaults in `byVault` are skipped entirely. The result is files physically binned with no pending-deletion record (so the removal won't propagate to drives — a sovereignty/sync gap) and a catalog that still lists them as present until some later rescan. The inconsistent mix of `try` (primary enqueue) and `try?` (the Live-pair enqueue on line 318) makes the still-vs-video paths behave differently on the same fault.
- **Suggested fix:** Wrap the primary enqueuePendingDeletion in the same resilience as the Live pair (log/continue rather than throw), or move enqueue before moveToBin so the queue and the physical move stay consistent, and ensure a rescan runs for every touched vault even on partial failure. Decide one policy for enqueue failures and apply it to both still and video.
- **Effort:** M

### M53 — XMP serializer emits raw XML-illegal control characters, producing an unparseable sidecar

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/Sidecar/XMP.swift:11-63`, `Sources/OpenPhotoCore/Sidecar/XMP.swift:65-67`
- **Problem:** esc() escapes only & < > and ". A caption or tag (or an imported Finder/Takeout tag) containing a C0 control character illegal in XML 1.0 (e.g. NUL, 0x01-0x08, 0x0B, 0x0C, 0x0E-0x1F) is written verbatim into element text. On the next read, XMP.parse calls `XMLDocument(data:)` which throws on the malformed document; SidecarStore.read propagates the throw (or ingest's try? folds it to skip), so the metadata round-trips to unreadable/empty. The human-authored value is effectively lost and the on-disk sidecar is corrupt for any third-party XMP reader. Captions are user-typed (paste can carry control chars) and tags can originate from foreign imports.
- **Suggested fix:** Strip or reject characters outside the XML 1.0 legal set (#x9 | #xA | #xD | #x20-#xD7FF | #xE000-#xFFFD | #x10000-#x10FFFF) in esc()/before serialization, or sanitize captions/tags at the SidecarData boundary. At minimum, validate that serialize output reparses before committing the write.
- **Effort:** S

### M54 — Eviction/rehydrate verification re-fetches the entire vault_presence table per item per drive

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService+Eviction.swift:138`, `Sources/OpenPhotoCore/LibraryService+Eviction.swift:41`, `Sources/OpenPhotoCore/LibraryService+Eviction.swift:87`, `Sources/OpenPhotoCore/LibraryService+DriveSource.swift:10`, `Sources/OpenPhotoCore/Catalog/Catalog.swift:277`
- **Problem:** verifyOnCanonical(.verified) calls `catalog.vaultPresenceRows(forVault:)` — a `SELECT … FROM vault_presence WHERE vaultID = ?` that materializes ALL rows for the drive — and then does a linear `.first(where: { $0.hash == hash })`, once for every item being evicted and for every connected drive (and twice when an item has a Live pair). driveSource and the rehydrate Live-pair lookup use the same full-fetch-then-linear-scan pattern. Cost is O(items × drives × presenceRows). On a large library (tens of thousands of rows) evicting/rehydrating a big selection re-reads the whole presence table from SQLite hundreds of times. The data is invariant across the loop.
- **Suggested fix:** Fetch each connected drive's presence rows once before the item loop and build a `[hash: VaultPresenceEntry]` dictionary (or add a `vaultPresenceRow(forVault:hash:)` indexed point query). Pass the prebuilt maps into verifyOnCanonical/driveSource so each lookup is O(1).
- **Effort:** M

### M55 — Human-metadata + Finder-tag save path is synchronous and does multi-file disk I/O on the main thread

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:229`, `Sources/OpenPhotoCore/LibraryService.swift:243`, `Sources/OpenPhotoCore/Sidecar/SidecarStore.swift:14`, `Sources/OpenPhotoCore/Interop/FinderTags.swift:11`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:418`
- **Problem:** LibraryService.updateMetadata and reconcileFinderTags are plain `throws` (not `async`) and perform disk I/O: an atomic XMP sidecar write, a catalog write, and — when Finder sync is on — reading the Finder xattr of EVERY local instance file (catalog.instances + FinderTags.read per URL) and writing the merged tag set back to every file plus a catalog baseline write. InspectorView.save() calls `tagsForSave` (→ reconcileFinderTags) and then `updateMetadata` and then `refreshQueries()` all synchronously from a SwiftUI view method on the main actor. For an asset with several instances (and slow/networked drives), this blocks the UI thread on per-file xattr reads/writes during a routine rating/caption/tag edit. The off-main bulk pass (syncFinderTagsNow) is correctly detached, which highlights that the per-edit path was simply not given the same treatment.
- **Suggested fix:** Make updateMetadata / reconcileFinderTags `async` (or have the inspector call them inside a Task.detached) so the sidecar write, catalog write, and especially the multi-file Finder xattr round-trips run off the main actor; update the inspector save() to `await` and then refresh on the main actor.
- **Verification:** Confirmed: AppState is @MainActor, so InspectorView.save() (line 418) synchronously calls tagsForSave→reconcileFinderTags (LibraryService:243, per-URL xattr reads via FinderTags.read + per-URL xattr writes via NSURL.setResourceValue + catalog baseline writes) and updateMetadata (atomic sidecar write + catalog write) on the main actor with no await/detach, while the bulk syncFinderTagsNow path is correctly Task.detached — so per-edit disk I/O does block the UI. Downgraded to Medium: it triggers only on a discrete save action and only does the multi-file xattr loop when finderTagSyncEnabled is on; the heavy multi-instance/slow-drive case is real but conditional rather than a hot-path/render blocker. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M56 — Rubber-band updateDrag re-scans the entire item list on every drag tick

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/Selection/SelectionModel.swift:81`, `Sources/OpenPhotoApp/Selection/SelectionUI.swift:91`, `Sources/OpenPhotoApp/Selection/SelectionUI.swift:112`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:97`
- **Problem:** updateDrag(rect:frames:items:) iterates the FULL `items` array (`for it in items where frames[it.id]?.intersects(rect) == true`) on every pointer-move event, and the auto-scroll loop re-invokes it every 16ms while held near an edge. The grids pass the complete ordered list (orderedSelectable = all state.flatItems), which for a 10k-photo timeline is a 10k-element scan many times per second during a drag — even though only on-screen cells have frames in `cellFrames`. The known dense-grid lag note makes this the kind of hot path worth bounding.
- **Suggested fix:** Iterate the populated `frames` dictionary (only on-screen/known cells) instead of the full `items` array, resolving each frame's id back to its SelectableItem via a `[String: SelectableItem]` lookup built once; or have callers pass only the candidate (visible) items. This bounds the per-tick work to visible cells.
- **Effort:** S

### M57 — Full-res read/decode failure is silently swallowed with no error state in the main viewer

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:241-247`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:146-153`
- **Problem:** In ViewerView.loadFull(), Data(contentsOf: url) uses try? and NSImage(data:) can return nil; both failures fall through with `if let data { fullImage = NSImage(data: data) }` and no else. When the file is unreadable, corrupt, or an unsupported format (e.g. a RAW NSImage can't decode), fullImage stays nil, item.kind is photo, driveUnplugged is false, playingLive is false, so content (ViewerView.swift:146-153) lands on the final `else { ProgressView() }` branch and spins forever with no error message and no way to know it failed. PeekViewer handles this correctly (it sets loadFailed and shows a 'Full-res isn't available' label, PeekView.swift:111-114/136); the primary viewer does not have an equivalent failure state.
- **Suggested fix:** Mirror PeekViewer: add a `@State private var loadFailed = false`, set it when the read or decode returns nil/throws, and add a content branch that shows a user-facing 'Couldn't open this photo' label instead of an infinite ProgressView. Distinguish from the legitimate still-loading state.
- **Effort:** S

### M58 — Video AVPlayer is created against a possibly-missing/oversized URL with no readiness or error surface

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:235-238`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:138-141`, `Sources/OpenPhotoApp/Peek/PeekView.swift:107-108`, `Sources/OpenPhotoApp/Peek/PeekView.swift:129-132`
- **Problem:** For a video, loadFull() does `player = AVPlayer(url: url)` and returns; fullResURL already filtered drive-only-unplugged, but for a local file the URL existence/integrity is not checked and AVPlayer never reports its status to the UI. If the file is missing/corrupt or the asset fails to load, the player area renders an empty/black PlayerView with no error. Worse, in ViewerView the video content branch is `if item.kind == video { if let player { PlayerView(player) } }` (138-141) with no else: if player is nil (e.g. a transient state, or a future code path where the player wasn't created) the user sees a blank stage with no spinner and no message. PeekViewer has the same `if let player` with no fallback (107-108).
- **Suggested fix:** Observe AVPlayer/AVPlayerItem status (KVO or `currentItem?.status`) and surface a failure label on .failed; show a ProgressView while status is .unknown. Add an else branch for the nil-player case so the video stage is never silently blank. Optionally verify FileManager.fileExists for local URLs before constructing the player to give an immediate 'missing file' message.
- **Effort:** M

### M59 — PeekViewer never tears down its AVPlayer — reintroduces the lingering/doubled-audio leak fixed in ViewerView

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Peek/PeekView.swift:69`, `Sources/OpenPhotoApp/Peek/PeekView.swift:127`, `Sources/OpenPhotoApp/Peek/PeekView.swift:128`, `Sources/OpenPhotoApp/Peek/PeekView.swift:130`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:216`
- **Problem:** PeekViewer.loadFull only does `player = nil` then `player = AVPlayer(url:)`; it never pauses or replaces the current item, and there is no onDisappear/teardown. This is the exact failure mode ViewerView.tearDownPlayer() documents (lines 216-221): merely dropping the AVPlayer reference keeps it alive and playing audio until it happens to dealloc, and navigating away then back stacks a second player (doubled audio). Stepping off a peeked video to another item, or pressing Done while a video plays, leaves audio playing. The teardown logic was written once in ViewerView and not shared, so the fix didn't propagate to the second, near-identical viewer — a duplicated-logic / leaky-abstraction problem with a concrete user-visible leak.
- **Suggested fix:** Extract the teardown into a shared helper (a small `func tearDown(_ player: inout AVPlayer?)` or a tiny wrapper type) and call it in PeekViewer: at the top of loadFull before reassigning, and from a new `.onDisappear`. Mirror ViewerView: `player?.pause(); player?.replaceCurrentItem(with: nil); player = nil`.
- **Verification:** PeekViewer.loadFull (PeekView.swift:128-130) drops the outgoing AVPlayer with bare `player = nil` (no pause/replaceCurrentItem) and PeekViewer has no `.onDisappear` teardown, whereas ViewerView documents (216-221) and uses tearDownPlayer() in both loadFull and .onDisappear — so the lingering/doubled-audio pattern is genuinely reintroduced and the fix wasn't shared. It's real but narrower than ViewerView's case: the player is created via `AVPlayer(url:)` without auto-`.play()`, so the leak only manifests after the user actually starts playback of a peeked video, making Medium more apt than High. (Severity adjusted from High to Medium on verification.)
- **Effort:** S

### M60 — Full original is loaded uncapped into memory with no downsampling or autorelease bounding

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** memory
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:241-246`, `Sources/OpenPhotoApp/Peek/PeekView.swift:135-136`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:316-318`
- **Problem:** The viewer reads the entire original file via Data(contentsOf: url) with no size guard, then NSImage(data:) and the subsequent cgImage(forProposedRect:) realize a full-resolution bitmap (width*height*4 bytes). A single 100 MP image is ~400 MB of decoded RGBA on top of the raw file Data; a RAW or panorama is worse. Rapid arrow-key stepping creates a new full Data + new full bitmap per step while the previous fullImage may not yet be released, and there is no autoreleasepool around the per-image work, so transient peak memory can spike to multiple GB. This is the same class of issue that previously OOM'd indexing (per project memory). Unlike the thumbnail path, nothing here downsamples to the actual on-screen size.
- **Suggested fix:** Downsample at decode time to the view's backing-pixel bounds (CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize = max display dimension * scale, kCGImageSourceCreateThumbnailFromImageAlways). For true 1:1 zoom support, keep a tile/region strategy rather than a single full bitmap. Avoid Data(contentsOf:) entirely (use a CGImageSource over the URL so ImageIO streams) and wrap the per-image decode in an autoreleasepool. Also nil out the previous image before decoding the next.
- **Verification:** Confirmed: ViewerView.loadFull (241-246) and PeekView.loadFull (135-136) read the entire original via Data(contentsOf:) then NSImage(data:), and ZoomPanLayerView.setImageIfChanged (317) realizes a full-resolution cgImage with no downsampling or autoreleasepool, even though ImageIO thumbnail downsampling and autoreleasepool are used elsewhere (ThumbnailStore, import sources, hashing). Downgraded to Medium because loadFull nils fullImage before decoding and .task(id:) cancels the prior detached load on rapid stepping, bounding in-flight bitmaps; the multi-GB spike only materializes for very-high-MP/RAW/panorama originals in interactive use. (Severity adjusted from High to Medium on verification.)
- **Effort:** M

### M61 — Full-image decode runs on the main actor in both viewers

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:241`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:245`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:317`, `Sources/OpenPhotoApp/Peek/PeekView.swift:135`, `Sources/OpenPhotoApp/Peek/PeekView.swift:136`
- **Problem:** Both viewers read the file bytes off-thread (`Data(contentsOf:)` in a detached task) but then construct `NSImage(data:)` on the main actor, and ZoomPanLayerView.setImageIfChanged later calls `image.cgImage(forProposedRect:context:hints:)` on the main thread. NSImage(data:) is lazy, so the actual bitmap decode of a large original (100MP HEIC, RAW, big PNG) happens on the main thread at first cgImage access — a main-thread hitch on full-res photos, exactly the 'full-image load on main thread' risk the subsystem flags. The off-thread Data load only moves the I/O, not the decode.
- **Suggested fix:** Decode to a downsampled CGImage entirely in the detached task using ImageIO (CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize ~ a few thousand px / screen-bounded, kCGImageSourceCreateThumbnailFromImageAlways), pass the CGImage (Sendable-safe via a box) back to the main actor, and hand that straight to the CALayer. This removes the main-thread decode and also bounds memory for huge originals.
- **Effort:** M

### M62 — Per-tile GPU texture blowup drives dense-grid lag (known, deferred)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Tiles/ThumbnailImage.swift:34`, `Sources/OpenPhotoApp/Tiles/ThumbnailImage.swift:11`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:83`
- **Problem:** Each visible cell renders its decoded CGImage via `Image(decorative:)`, so SwiftUI uploads one GPU texture per tile. At minimum zoom the adaptive LazyVGrid materializes a very large number of simultaneous tiles, and the shared NSCache keeps up to 6000 decoded images alive (countLimit only, no byte cost limit), so a Space switch / scroll-to-min-zoom produces a texture-upload spike and visible hitch. This matches the documented dense-grid lag; it is already root-caused and the tiled-renderer fix is deferred to Phase 5, noted here for completeness so it isn't lost in this audit.
- **Suggested fix:** Already planned: replace per-image Image views with a single tiled/atlassed renderer (one Canvas/Metal layer drawing many thumbnails) so the number of GPU textures is bounded by viewport, not item count. Interim mitigation: add a totalCostLimit to tileMemoryCache (set cost = bytes per image) to bound resident decoded memory.
- **Effort:** L

### M63 — TimelineView.body re-scans the full timeline list multiple times per render

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Timeline/TimelineView.swift:18`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:22`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:23`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:32`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:45`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:188`
- **Problem:** `selectedItems` filters all of state.flatItems (a Set.contains per item), and `evictableItems`/`rehydratableItems`/`stats` chain off it or re-filter the full list. The alert titles interpolate `evictableItems.count` at lines 32 and 45, which SwiftUI evaluates eagerly every time body builds the modifiers — so each body pass does several O(n) passes over the 10k-item list. Because AppState is @Observable, body re-runs on any observed read that changes (selection toggles, grid slider, grouping, presence reloads), so these scans repeat on routine interactions. Not catastrophic at 10k, but it scales linearly with the whole library on every selection tap and is avoidable.
- **Suggested fix:** Compute selectedItems/evictableItems once per body into a local `let`, or better derive the counts from the SelectionModel's id set + an index map without rescanning the whole array. Move the alert-title counts to read `selection.count` (or a cached evictable count) so the destructive-count strings don't force a full filter on every render.
- **Effort:** S

### M64 — Search result race: overlapping un-cancelled Tasks can publish stale results

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoApp/AppState.swift:485`, `Sources/OpenPhotoApp/AppState.swift:519`, `Sources/OpenPhotoApp/AppState.swift:521`, `Sources/OpenPhotoApp/Search/SearchView.swift:54`, `Sources/OpenPhotoApp/Search/SearchView.swift:166`, `Sources/OpenPhotoApp/Search/ProFilterBar.swift:123`
- **Problem:** runSearch() spawns a new unstructured `Task { ... }` on every invocation and never stores or cancels the previous one. The text path is debounced (300ms in SearchView.debounce), but the Pro/Simple filter bars call state.runSearch() directly on every chip/menu/toggle tap, and `.onSubmit` also calls it directly — none of these are debounced. Two searches can therefore be in flight at once; because the off-main detached work (SQL + CLIP embed + Accelerate) has variable latency, the OLDER search can finish last and overwrite `searchResults`/`searching` with stale data. There is no generation token guarding the `self.searchResults = items` assignment at line 521, so last-to-finish wins rather than last-requested. The user sees results that don't match the current filter/query, and `searching` may be left in the wrong state.
- **Suggested fix:** Serialize searches: store the Task in a property and cancel it at the top of runSearch() (`searchTask?.cancel(); searchTask = Task { ... }`), and/or stamp each run with a monotonically increasing generation Int captured before the detached work; on completion, bail (`guard gen == currentSearchGen`) before assigning searchResults. Also route the un-debounced filter-bar taps through the same debounce as the text box, or at least guard against re-entrancy.
- **Verification:** runSearch() (AppState.swift:485) spawns an unstructured Task running variable-latency detached work (SQL + CLIP embed + optional SemanticIndex rebuild) and unconditionally assigns self.searchResults/self.searching at 521-522 with no stored Task, no cancellation, and no generation guard; the many un-debounced filter-bar/onSubmit callers (ProFilterBar/SimpleFilterBar) can put two searches in flight, and the rebuild-vs-cached latency asymmetry makes an older search plausibly finish last and overwrite fresh results. @MainActor serializes the writes (no crash/data race), so the impact is transient stale UI results/spinner state, not corruption — Medium rather than High. (Severity adjusted from High to Medium on verification.)
- **Effort:** S

### M65 — Entire search path swallows errors via try? → silent empty/partial results, no user-facing failure

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Search/Catalog+Search.swift:119`, `Sources/OpenPhotoCore/Search/Catalog+Search.swift:131-133`, `Sources/OpenPhotoApp/AppState.swift:490-498`, `Sources/OpenPhotoApp/AppState.swift:517`
- **Problem:** Every database call in the search lanes is wrapped in `try?` and coalesced to an empty array: `searchOCR` (Catalog+Search.swift:119), the caption/tag LIKE lane (:131-133), and in runSearch `allHashesNewestFirst`, `structuredFilter`, `textMatches`, and `items(forHashes:)` (AppState.swift:490-517). Consequences: (a) a malformed FTS5 MATCH expression or any SQLite error makes that lane silently return nothing, so the user sees fewer/zero results and cannot tell search succeeded-with-no-matches from search-failed; (b) if `structuredFilter` throws, `structured` becomes `[]`, which combined with `hasText` semantics yields an empty result set that looks like 'no photos match' rather than an error. There is no error surface — `searching` simply flips to false with `searchResults = []`. For a sovereignty-focused app this masks real catalog corruption.
- **Suggested fix:** Propagate errors at least to a diagnostic surface: have runSearch catch and set an `@Published searchError` (or log + show a non-blocking banner) instead of `try?`-to-empty. Distinguish 'no matches' (empty result, no error) from 'query failed' (error state). At minimum log the thrown error in each lane rather than discarding it.
- **Effort:** M

### M66 — SemanticIndex trusts declared dim over decoded vector length → vDSP_mmul out-of-bounds

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Search/SemanticIndex.swift:18-22`, `Sources/OpenPhotoCore/Search/SemanticIndex.swift:34`, `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:11-18`, `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:47-55`
- **Problem:** The constructor keeps rows where `$0.dim == dim`, but `dim` here is the DB integer column (`allEmbeddings` reads `row["dim"]`), NOT the actual length of the decoded vector. `unpackFloat16` deliberately fills only `0..<min(dim, halves.count)` floats, so if a stored `vector` blob is shorter than `dim` bytes-worth (truncated/corrupt blob, a half-written or partially-migrated row, or any future packing skew), the row still passes the `r.dim == dim` filter yet appends fewer than `dim` floats to `matrix`. The matrix is then shorter than `count*dim`, but `vDSP_mmul` is told the dimensions are exactly `count × dim` (line 34). vDSP reads `count*dim` contiguous floats with no bounds check, walking past the end of the backing buffer → crash or silently corrupted cosine scores for every query. The comment at lines 15-17 claims the dim filter prevents exactly this out-of-bounds, but it only guards against a *different* declared dim, not against a vector whose decoded length disagrees with its own declared dim.
- **Suggested fix:** Filter on the real decoded length, not the declared column: `let usable = rows.filter { $0.dim == dim && $0.vector.count == dim }`. Optionally assert `m.count == usable.count * dim` after building the matrix and bail (return empty index) if it ever mismatches, so a corrupt blob degrades to 'no semantic results' instead of an OOB read.
- **Verification:** Verified the chain: allEmbeddings returns the DB `dim` column (Catalog+Embeddings.swift:51) while unpackFloat16 fills only min(dim, halves.count) floats (line 15), and SemanticIndex.init filters on `$0.dim == dim` (declared dim) not the decoded vector length (SemanticIndex.swift:17), then feeds vDSP_mmul exact count×dim with no bounds check (line 34) — so any row whose blob is shorter than dim*2 bytes makes `matrix` shorter than count*dim and vDSP reads out of bounds; the inline comment claiming this filter prevents the OOB is wrong. Real latent memory-safety/correctness defect, but downgraded to Medium because it requires a truncated/corrupt/dim-mismatched blob (the normal write path uses a constant dim=512 and a model-sized vector), so it cannot occur on the happy path with the current single model. (Severity adjusted from High to Medium on verification.)
- **Effort:** S

### M67 — Silent error swallowing across the search pipeline hides failures as empty results

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoApp/AppState.swift:490`, `Sources/OpenPhotoApp/AppState.swift:492`, `Sources/OpenPhotoApp/AppState.swift:495`, `Sources/OpenPhotoApp/AppState.swift:498`, `Sources/OpenPhotoApp/AppState.swift:503`, `Sources/OpenPhotoApp/AppState.swift:517`, `Sources/OpenPhotoCore/Search/Catalog+Search.swift:119`, `Sources/OpenPhotoCore/Search/Catalog+Search.swift:131`
- **Problem:** Every fallible call in the search path is wrapped in `try?` with `?? []`: allHashesNewestFirst, structuredFilter, items(forHashes:), textMatches, SemanticIndex construction, and inside textMatches both the OCR lane (try? searchOCR) and the LIKE lane (try? dbQueue.read). A malformed FTS5 MATCH expression, a too-large IN list, an embeddings-table corruption, or any GRDB error therefore disappears and renders identically to a legitimate 'No matches' empty state (SearchView.swift:102). This makes the risky areas (FTS query construction, dedup-by-MIN(rowid) union, embeddings load) effectively untestable from the UI and undiagnosable in the field — directly counter to the project's sovereignty/auditability ethos.
- **Suggested fix:** Let errors propagate to a single place in runSearch() where they can be logged (NSLog/os_log) and optionally surfaced (e.g. a distinct 'search failed' state vs 'no matches'). Keep `?? []` only where empty is genuinely correct (e.g. trimmed-empty query), not where it masks a thrown error.
- **Effort:** M

### M68 — Loose filters / empty-query path materializes the whole library into Swift arrays and a giant IN(?) bind list

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoApp/AppState.swift:490`, `Sources/OpenPhotoApp/AppState.swift:492`, `Sources/OpenPhotoApp/AppState.swift:495`, `Sources/OpenPhotoCore/Search/Catalog+Search.swift:164`, `Sources/OpenPhotoCore/Search/Catalog+Search.swift:187`, `Sources/OpenPhotoCore/Search/SearchRanker.swift:54`
- **Problem:** When a query string is empty but filters are set, runSearch() calls structuredFilter(filters) → a [String] of every matching hash (can be the entire library for a loose filter like favoritesOnly=false-only or a single broad folder), then passes that whole array straight into items(forHashes:preservingOrder:) which builds `WHERE hash IN (\(marks))` with one `?` bind per hash. On a 10k+ library (the stated acceptance test) this creates a 10k-element StatementArguments and a 10k-placeholder IN list, which is both slow to prepare and can exceed SQLite's SQLITE_MAX_VARIABLE_NUMBER (999 on older builds), throwing — and the throw is swallowed by `try?` at line 495, silently yielding empty results with no error surfaced. SearchRanker.combine also builds `Set(structured)` over the full library on every text search (line 54), O(library) per keystroke after debounce.
- **Suggested fix:** For large hash sets, fetch via a temp table / carray / chunked IN batches rather than one mega bind list, or have structuredFilter return TimelineItems directly (single SQL pass on the union with the WHERE applied) instead of round-tripping hashes back through items(forHashes:). At minimum, chunk the IN list to < 900 binds and stop swallowing the error so a failure is visible rather than presenting as 'No matches'.
- **Effort:** M

### M69 — FolderWatcher.stop() may run off the owning context via deinit, and the FSEvents callback can fire during teardown

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** concurrency
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/FolderWatcher.swift:55-61`, `Sources/OpenPhotoCore/Scanner/FolderWatcher.swift:63-72`, `Sources/OpenPhotoApp/AppState.swift:1734-1737`
- **Problem:** stop() is documented as not concurrency-safe and required to be called from a single owning context, but `deinit { stop() }` runs on whatever thread releases the last reference, which is not guaranteed to be that context. start()/stop() mutate `streamRef` and `pending` without synchronization while the FSEvents callback runs on `queue` and calls scheduleFire() (which also mutates `pending`). If a debounced event fires concurrently with stop()/deinit there is an unsynchronized read/write of `pending` and a small window where the C callback dereferences `info` (passUnretained self) during deallocation. In practice AppState owns the watcher and calls stop() on @MainActor before nil-ing it, which mostly avoids this, but the class is marked @unchecked Sendable and the invariant is enforced only by convention.
- **Suggested fix:** Serialize all streamRef/pending access on `queue` (or an internal lock). In stop(), set the FSEvents callback's context to nil / invalidate on `queue` and cancel `pending` there, so a concurrent callback can't touch a half-torn-down instance. Consider not relying on deinit for teardown.
- **Effort:** M

### M70 — Manifest fast-path can silently miss content edits (size+mtime unchanged)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/Scanner.swift:64-67`, `Sources/OpenPhotoCore/Vault/VaultDescriptor.swift:42-46`
- **Problem:** The fast-path reuses the stored hash when `old.size == s && old.mtime == mtimeStr`. An in-place edit that preserves byte length and restores mtime (e.g. a metadata tool writing back with `touch -r`, some sync tools, or an editor that pads to the same size) is skipped and keeps the stale hash, so the catalog/manifest silently diverge from the actual bytes. Additionally mtime is serialized via ISO8601 with `.withFractionalSeconds` (millisecond truncation), so two edits within the same millisecond, or filesystems whose mtime resolution is coarser than what was previously recorded, can compare equal across a real change. This is the documented risk in the focus brief; it is a correctness/data-integrity issue (a later hash-verified copy or sync would propagate the stale hash).
- **Suggested fix:** Acceptable as a deliberate perf trade-off, but document it in docs/format and consider a cheap guard: also compare against a periodic full rehash, or treat any mtime within a small epsilon of 'now' as dirty. At minimum, ensure the manifest mtime precision matches the source so equality is meaningful.
- **Effort:** M

### M71 — Scan silently drops files on attribute/read errors with no user-facing surfacing

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/Scanner.swift:48-52`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:79-83`, `Sources/OpenPhotoCore/LibraryService.swift:70-79`
- **Problem:** Two catch blocks in scan just `skipped += 1; continue` (unreadable attributes, unreadable file body), and ingestSidecars uses `try? store.read(...)` to swallow corrupt sidecars. The Result exposes a `skipped` count but nothing in the audited path turns a non-zero `skipped` into a user-visible warning, so a transient permission glitch or a flaky external drive can silently omit real photos from the index with no signal to the user (and they would then look 'missing' or be eligible for free-up as only-on-this-Mac). The sidecar swallow can silently lose human-authored metadata (rating/caption/tags) if a sidecar is malformed.
- **Suggested fix:** Propagate skipped/error counts to a user-facing indexing summary ('N files could not be read'), and log which paths failed (at least at debug level). For sidecars, distinguish 'no sidecar' from 'sidecar present but unparseable' and surface the latter rather than treating it as empty metadata.
- **Effort:** M

### M72 — PresenceService.locations() amplifies into O(items × drive-vaults) full-set SQL reads

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Presence/PresenceService.swift:45-95`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:57-66`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:99-112`, `Sources/OpenPhotoCore/Catalog/Catalog.swift:288-293`, `Sources/OpenPhotoApp/AppState.swift:1564-1567`
- **Problem:** locations(forHash:) issues, per call: one catalog.instances() query, one registeredVaults() query, and then for EVERY non-local registered vault a full catalog.vaultPresenceHashes(forVault:) which does `SELECT hash FROM vault_presence` and materializes the entire vault's hash Set just to test `.contains(hash)`. isOnlyOnThisMac(hash:) calls locations() once, and onlyOnThisMac(hashes:) (AppState.onlyCopyCount) calls isOnlyOnThisMac once per item. So evicting/deleting a K-item selection with V drive vaults registered performs K×(1 instances + 1 registeredVaults + V full vault_presence table scans). For thousands of selected items this is thousands of redundant whole-table reads of identical data. It's gated behind alert presentation (not per-render), but is still a sharp, avoidable cost spike at the moment of a bulk action.
- **Suggested fix:** Hoist the per-vault state out of the per-hash path: fetch registeredVaults() once and load each vault's presence set once (or expose a batch catalog query `vaultsContaining(hashes:)` / a single membership query keyed on hash), then test membership in memory. For the only-copy判断, a single `SELECT DISTINCT hash FROM vault_presence WHERE hash IN (...)` plus the sends/imports lookups would replace the K×V scans with O(1) queries.
- **Effort:** M

### M73 — Scan pipeline is fully single-threaded (serial walk, hash, and metadata extract)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/Scanner.swift:29-53`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:63-85`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:91-122`
- **Problem:** All three phases run as plain serial for-loops on a single task. The hash loop reads and SHA-hashes each new file one at a time, and the extract loop does `await MetadataExtractor.extract(...)` (which itself awaits AVAsset.load for videos and runs ImageIO synchronously for photos) sequentially per file. On a large library (the 10k-import acceptance case noted in project memory) this leaves most CPU cores and disk bandwidth idle and makes the initial index far slower than necessary. Hashing and metadata extraction are embarrassingly parallel and independent per file.
- **Suggested fix:** Process the hash and extract phases with a bounded-concurrency TaskGroup (e.g. ProcessInfo.activeProcessorCount workers, or a small fixed cap to bound memory) instead of a serial loop, collecting results into the aligned/newAssets arrays. Keep the autoreleasepool discipline inside each worker. Note the parallelism width must be bounded given the prior 41GB OOM history.
- **Effort:** M

### M74 — Synchronous DB queries run inside InspectorView.body on every recomputation

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:129`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:145`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:23`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:45-95`, `Sources/OpenPhotoCore/Catalog/Catalog+Geocode.swift:47-55`
- **Problem:** InspectorView is `@Bindable var state` so its body recomputes on any observed AppState change. The body issues blocking SQLite reads each time: `state.library?.catalog.geocode(forHash:)` (a `dbQueue.read` with SQL) at line 129, and `state.locations(for: item)` at line 145 which calls PresenceService.locations() — that runs several reads per call (instances, registeredVaults, vaultPresenceHashes, plus sends/imports/devices scans). These are side-effecting reads performed on the main actor synchronously during view evaluation, repeated on every render rather than computed once per item. On a large/multi-vault library this adds main-thread DB work to routine UI updates (e.g. a star tap that mutates state and re-renders the inspector re-runs all of it).
- **Suggested fix:** Compute geocode and locations once per item off-main and cache into @State, refreshed from `.task(id: item.hash)` alongside load()/loadFaces(), instead of calling them inline in body. Render from the cached values.
- **Effort:** M

### M75 — CleanupView selection re-seed key ignores group membership changes

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:33-46`, `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:59`
- **Problem:** groupsSignature is `state.cullGroups.map { $0.keep + "#\($0.items.count)" }` and drives `.onChange(of: groupsSignature) { seedSelection() }`. The signature is insensitive to which items are in a group: if a reload produces groups with the same keeper hash and the same count but different membership (e.g. an item was deleted and a different near-duplicate took its place, or duplicate/similar grouping shuffled members while count/keeper stayed constant), onChange does not fire and the pre-seeded suggested-evict selection is not refreshed. The shared SelectionModel is keyed by instanceID, so stale entries simply won't match new tiles (benign) but newly-suggested rejects in the changed group won't be pre-selected — the user sees a group whose suggestions aren't reflected. After deleteSelected()/applyAllSuggestions() call loadCullGroups(), a same-keeper/same-count regrouping would also fail to re-seed.
- **Suggested fix:** Make the signature membership-sensitive, e.g. fold each group's sorted instanceIDs (or hashes) and its suggestedEvict set into the key, so any change in composition reseeds. A cheap version: `state.cullGroups.map { $0.keep + "#" + $0.items.map(\.instanceID).joined(separator: ",") }`.
- **Effort:** S

### M76 — In-progress caption / new-tag text is lost when switching photos (no debounce or flush)

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:41`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:44`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:94`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:230`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:398`
- **Problem:** The caption field commits only on onSubmit (Return); the 'Add tag' field commits only on its onSubmit. When the user navigates to another photo (arrow keys / clicking another result), `.task(id: item.hash)` fires load() which overwrites `caption`, `tags`, etc. from the new item. Any caption text typed but not submitted, and any half-typed new tag, is silently discarded — a classic fast-switch lost edit. There is no onDisappear/onChange flush and no auto-save debounce, so the only safe way to keep a caption is to remember to press Return every time.
- **Suggested fix:** Flush pending caption/newTag on item change (in the .task(id:) before reloading, or via onChange(of: item.hash)) and/or save the caption on a short debounce as the user types, matching how rating/favourite already auto-save.
- **Effort:** S

### M77 — Inspector Delete/Evict advances within flatItems, not the viewer's actual item set

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:234`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:242`, `Sources/OpenPhotoApp/AppState.swift:1649`, `Sources/OpenPhotoApp/AppState.swift:1651`, `Sources/OpenPhotoApp/AppState.swift:1653`, `Sources/OpenPhotoApp/Search/SearchView.swift:129`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:14`
- **Problem:** The Inspector's Delete and Evict confirmations call state.removeOpenedItem, which computes the next photo using state.flatItems (the full timeline). But the viewer can be opened over a filtered set: SearchView calls openViewer(item, within: state.searchResults) and folder grids open within one folder, both of which set viewerItems, and the viewer navigates viewerItems (ViewerView.flatItems = viewerItems when non-empty). So deleting/evicting from the viewer while browsing Search results or a single folder jumps to the next item in the entire library timeline instead of the next result/folder item — wrong, surprising navigation that can also land on a photo not in the current context.
- **Suggested fix:** Make removeOpenedItem advance within the same list the viewer is using (viewerItems when non-empty, else flatItems), mirroring ViewerView.flatItems. Pass the active list in, or have removeOpenedItem read the same source ViewerView does.
- **Effort:** S

### M78 — Sidecar/catalog write failures in Inspector are swallowed with no user-facing error

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:420`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:424`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:425`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:402`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:408`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:409`
- **Problem:** save() wraps the only durable write (lib.updateMetadata, which writes the human-metadata XMP sidecar) in `try?`, and refreshQueries() in `try?`. If the sidecar write fails (drive full, permissions, ejected mid-edit) the user sees the rating star fill or the tag chip appear (the @State already changed), but nothing was persisted and no alert is shown — a silent loss of human-authored metadata, which the project treats as the sovereign source of truth. load() at line 402 and loadFaces() at 408-409 also silently fall back to empty on decode/DB error, so corrupt tagsJSON quietly drops all tags.
- **Suggested fix:** Catch the error from updateMetadata and surface it (NSAlert / inline error state) and revert the @State so the UI reflects what was actually persisted. At minimum, do not present an edit as committed when the durable write threw.
- **Effort:** S

### M79 — Metadata save blocks the main actor with file I/O and a full library re-query

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:418-426`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:51-65`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:94-100`, `Sources/OpenPhotoApp/AppState.swift:120-123`, `Sources/OpenPhotoApp/AppState.swift:1531-1547`, `Sources/OpenPhotoCore/LibraryService.swift:229-257`
- **Problem:** save() runs entirely on @MainActor and synchronously performs: (1) tagsForSave → reconcileFinderTags, which (when Finder-tag sync is on) reads and re-writes macOS Finder tags on EVERY local instance file (filesystem I/O); (2) lib.updateMetadata → an atomic XMP sidecar write (temp→fsync→rename) plus a catalog SQL write; (3) state.refreshQueries(), which re-runs timelineSections, folderTree, binItems and pending-deletion refresh over the whole library. This fires on every star click, favorite toggle, and tag add/remove. Each interaction therefore does sidecar file I/O + (optionally) per-file Finder I/O + a full timeline/folder re-query on the main thread, hitching the UI on large libraries. (Correctness of the write is fine — durable-first ordering is preserved; this is purely a main-thread blocking / responsiveness problem.)
- **Suggested fix:** Move the write + reconcile to a detached task (it already runs serially per-item) and only hop back to the main actor to update openedItem. Make refreshQueries incremental for single-item metadata edits (patch the affected item in `sections`/`flatItems`) instead of re-querying the entire library on every star tap.
- **Effort:** M

### M80 — No free-space preflight before volume copy-out

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:38`, `Sources/OpenPhotoCore/Send/SendEngine.swift:44`, `Sources/OpenPhotoApp/AppState.swift:1722`
- **Problem:** The send path copies items one-by-one into the destination folder with no check that the volume has room for the selection. Every other copy path in the codebase preflights free space (SyncEngine.swift:128 checks `free < plan.totalCopyBytes`; ImportEngine.swift:67 reads volumeAvailableCapacityForImportantUsage), but VolumeCopyDestination.send does not. Sending e.g. 50 GB to a near-full SD card will attempt-then-fail each file individually (copyItem throws ENOSPC, cleanup runs, item marked failed), producing a slow drip of failures rather than an upfront 'not enough space' message. On exFAT/FAT cards (the common SD case) the partial successes also leave the card in a half-populated state with no clear total-space warning.
- **Suggested fix:** Before the copy loop, sum the item sizes (fingerprint.size is already available) and compare against the volume's free space via the existing DriveVolume.freeSpaceBytes()/volumeAvailableCapacityForImportantUsage helper; if insufficient, return all items as .failed with an 'insufficient space' error (or surface it to the sheet) instead of copying until ENOSPC.
- **Effort:** S

### M81 — Swallowed enumeration failure silently disables dedup and re-copies everything

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/SendEngine.swift:31`, `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:32`
- **Problem:** Live dedup is the ONLY dedup the engine performs (it never consults SendRegistry on the send path). `let present = (try? await destination.enumeratePresent()) ?? []` turns any enumeration error (permission failure, transient I/O error on the removable volume) into an empty present-set, so isPresent() returns false for every item and the engine re-sends the entire selection. Because the volume destination uses collisionFreeURL, those re-sends do not overwrite — they create IMG (2).JPG, IMG (3).JPG duplicates on the card. Separately, inside enumeratePresent each file's hash is `try?`-wrapped (VolumeCopyDestination.swift:32): a file that fails to hash is recorded with hash:nil and falls back to loose size+capture-second matching, which can both false-miss (re-copy) and, for two same-size same-second files, false-match (skip a genuinely-new file). The failure is invisible to the user — no 'couldn't read the device' signal.
- **Suggested fix:** Distinguish 'enumeration threw' from 'device is empty', as the reverify path already does (AppState.swift:1690 bails on a thrown enumeration rather than treating it as empty). On a thrown enumeration, either abort the send with a surfaced error or fall back to SendRegistry.contains(destinationKey:hash:) for dedup so prior confirmed sends are still skipped, rather than silently re-copying.
- **Effort:** M

### M82 — fsync durability check is bypassed when the file handle cannot be opened

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:50`
- **Problem:** The flush-before-verify guard is wrapped in `if let fh = try? FileHandle(forUpdating: target)`. The comment states the flush is required so an unmount between copy and hash can't verify against unflushed page-cache data (invariant #4). But if `FileHandle(forUpdating:)` itself fails (the `try?` yields nil — possible on read-only-after-write quirks, exFAT permission oddities, or a momentarily-busy file), the entire flush block is skipped and execution proceeds straight to hashing and confirmation with NO fsync. The very durability guarantee the code documents is silently dropped exactly in the error case it was meant to protect against. (Inside the block the flush result is checked, but failing to even open the handle escapes the check.)
- **Suggested fix:** Treat an un-openable handle as a flush failure: change to `guard let fh = try? FileHandle(forUpdating: target) else { remove + mark failed('flush failed') }`, or open the handle with a throwing `try` inside the existing do/catch so the failure routes to the catch + cleanup path rather than skipping verification.
- **Effort:** S

### M83 — Bin "Restore" swallows its error — failed restores silently do nothing

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Bin/BinView.swift:38`, `Sources/OpenPhotoApp/Bin/BinView.swift:40`, `Sources/OpenPhotoCore/Vault/BinStore.swift:42`, `Sources/OpenPhotoCore/Vault/BinStore.swift:47`
- **Problem:** The Restore button does `try? await state.library?.restore(entry)` (BinView.swift:40), discarding any thrown error. LibraryService.restore → BinStore.restore performs `fm.moveItem(at: src, to: dst)` (BinStore.swift:47), which throws NSFileWriteFileExistsError if the original path is now occupied (a new file was imported/created there since deletion), or throws on a permissions/disk-full failure. In all those cases the move fails, `writeLog(... filter ...)` after it never runs (so the entry stays in the bin log and reappears), and the user sees the button do nothing with NO feedback. This is inconsistent with confirmEmpty() in the same file, which surfaces failures via NSAlert(error:). Restore is a user-initiated recovery action where silent failure is especially surprising.
- **Suggested fix:** Replace the `try?` with a do/catch that presents NSAlert(error:) on failure (mirroring confirmEmpty at BinView.swift:66), e.g. `do { try await state.library?.restore(entry); try state.refreshQueries() } catch { NSAlert(error: error).runModal() }`. Optionally have BinStore.restore detect an occupied destination and either restore under a disambiguated name or report a specific, actionable message.
- **Effort:** S

### M84 — Bin restore failures are swallowed silently

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Bin/BinView.swift:38-43`, `Sources/OpenPhotoCore/Vault/BinStore.swift:42-56`
- **Problem:** The Restore button runs `try? await state.library?.restore(entry)` and `try? state.refreshQueries()`, discarding any error. `BinStore.restore` does `FileManager.moveItem(at: binnedSrc, to: originalDst)`, which throws if a file already exists at the original path (e.g. the user re-imported or re-created a file with the same relative path after deleting it, or the original folder was renamed/removed). On failure the item silently stays in the bin with no feedback — the user clicks Restore, nothing visibly happens, and they have no idea why. This directly undercuts invariant (3): deletion is supposed to be a reversible move-to-bin, so a restore that can fail invisibly makes the bin feel like it ate the file. Note the in-flight item is never hard-lost (it's still in bin/), but the experience reads as data loss.
- **Suggested fix:** Capture the error and surface it. Wrap the restore in do/catch and present `NSAlert(error:).runModal()` (matching the pattern already used in `confirmEmpty()`), or better, set an `@State` error banner. For the common name-collision case, BinStore.restore could detect an existing destination and restore under a deduped name (e.g. `name (restored).ext`) rather than throwing, so the user always gets their file back.
- **Effort:** S

### M85 — Empty-Bin flow bypasses LibraryService/BinStore and manipulates the bin on disk directly

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Bin/BinView.swift:53-71`, `Sources/OpenPhotoCore/Vault/BinStore.swift:70-76`, `Sources/OpenPhotoCore/LibraryService.swift:338-348`
- **Problem:** `confirmEmpty()` reaches past the LibraryService/BinStore abstraction: it iterates `state.library.vaults`, trashes each `vault.binDirURL` with FileManager directly, and writes an empty `binLogURL` via `AtomicFile.write(Data(), ...)` itself. This duplicates BinStore's log-management logic in the UI layer and couples the view to the on-disk vault layout (binDirURL/binLogURL). Two concrete risks: (1) if LibraryService or any registry holds an in-memory BinStore/list cache, it is not invalidated here, so it can go stale relative to disk until the next rescan; (2) the partial-failure handling is per-vault but inconsistent — if `trashItem` succeeds but writing the empty log later throws, you've trashed the files yet kept a non-empty log referencing now-missing files. The 'empty the bin' operation belongs behind a single `LibraryService.emptyBin()` (or `BinStore.empty()`) that owns the trash+log+cache-invalidation as one unit.
- **Suggested fix:** Add `func emptyBin() throws` to LibraryService that, per vault, trashes the bin dir and truncates the log atomically and invalidates any cached bin state, then have BinView call `try state.library?.emptyBin()`. Keep the confirm alert in the view; move all file/log mutation into Core.
- **Effort:** M

### M86 — Final manifest rewrite in apply() is swallowed by try?, losing the record of copied files

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/SyncEngine.swift:187`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:122`
- **Problem:** After copying files and writing sidecars, apply() persists the verified manifest with `try? Manifest.write(...)`. If that write fails (disk full from the manifest itself, drive yanked during the rewrite, permissions), the error is discarded: the function returns a SyncResult reporting N files copied while the on-disk manifest still reflects the OLD state. The copied files now exist on the drive but are absent from the manifest, so the next drift scan flags them all as `.unknown` and the next plan() re-copies them (VerifiedCopy will refuse-then-conflict since they already exist). The user sees success but the drive's authoritative record silently diverges from reality, with no error surfaced in SyncResult.
- **Suggested fix:** Capture the manifest-write outcome (don't use try?); on failure, record it on SyncResult (e.g. a `manifestWriteFailed` flag or move all just-copied items into `failed`) so the caller can alert the user and retry. Self-heal is real but should be observable, not silent.
- **Effort:** S

### M87 — One corrupt manifest line aborts the whole read, making a drive look empty

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Vault/Manifest.swift:50`, `Sources/OpenPhotoCore/Vault/Manifest.swift:60`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:14`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:74`, `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift:75`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:28`
- **Problem:** Manifest.read maps every non-empty line through `try decoder.decode(...)`, so a SINGLE malformed/truncated JSONL line (e.g. a partial last line from a power loss on a non-atomic external write, or any future format drift) throws and the ENTIRE manifest read fails. Consumers react badly: SyncEngine.plan/planClone would throw (sync aborts), and any code path that wraps the read in `try?` (DriftReconciler is called via `try? scan`, apply seeds `verified` via `try? Manifest.read`) silently treats the drive as having ZERO known files — which makes the sync planner re-queue copies for everything and makes drift report everything as `unknown`. A drive whose manifest is 99% intact is rendered fully unusable by one bad byte.
- **Suggested fix:** Make read line-tolerant: decode per line in a do/catch, skip+log undecodable lines (or collect them into a recoverable-error count) instead of failing the whole file. The manifest is sorted/rewritten atomically elsewhere, so dropping a single corrupt line is safe and self-healing. Surface a count of skipped lines so the UI can warn rather than silently lose entries.
- **Effort:** S

### M88 — Drive yanked mid-walk corrupts presence by reporting good files as missing

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:7`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:11`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:27`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift:134`, `Sources/OpenPhotoApp/AppState.swift:1113`, `Sources/OpenPhotoApp/AppState.swift:1117`
- **Problem:** walk() builds the on-disk map with FileManager.enumerator and silently continues past any resourceValues error (`guard ... else { continue }`); if the drive is unplugged or goes offline mid-enumeration, enumerator simply stops and walk() returns a TRUNCATED map with no error signal. scan()/verify() then classify every manifest entry not seen as `.missing` (or size/mtime-changed). driftScan() (AppState.swift:1117) immediately feeds report.presentHashes into replaceVaultPresence, which DELETEs and rewrites the whole vault_presence set — so a transient mid-scan yank wipes presence for files that are perfectly intact and surfaces them as phantom 'missing/lost' in the UI until a clean rescan. Originals are never touched (no data loss), but the derived presence/drift view is corrupted by a benign physical event the code can't distinguish from real loss.
- **Suggested fix:** Detect a truncated walk: after enumerating, re-check volume.isMounted / FileManager.fileExists(rootURL) (and ideally compare enumerator completion) before trusting an empty-or-shrunken on-disk map; if the root became unreachable, abort the scan with a thrown error rather than producing a DriftReport, and have driftScan() skip the replaceVaultPresence overwrite on that error. At minimum, do not overwrite presence when the scan saw zero on-disk files but the manifest is non-empty.
- **Effort:** M

### M89 — Adopt/restore/acknowledge run file hashing and manifest rewrites on the main actor

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1234`, `Sources/OpenPhotoApp/AppState.swift:1255`, `Sources/OpenPhotoApp/AppState.swift:1272`, `Sources/OpenPhotoApp/AppState.swift:1241`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:66`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:72`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:86`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:99`
- **Problem:** AppState is @MainActor. adoptDriftFile/adoptAll/restoreDriftFile/restoreAllRecoverable/acknowledgeGone are synchronous @MainActor methods that perform blocking work: adopt() hashes the file via ContentHash.ofFile and rewrites the manifest; restore() runs VerifiedCopy.copy (full file copy + re-hash) plus a manifest rewrite. The DriftReviewSheet buttons call these directly with no Task/off-main hop. So adopting or restoring a large file (or 'Adopt all'/'Restore all') hashes/copies on the main thread and freezes the UI. This is inconsistent with the sibling paths repairFinding/verifyIntegrity, which correctly wrap the same kind of work in Task.detached(priority: .userInitiated).
- **Suggested fix:** Make adopt/restore/acknowledge async and run the DriftReconciler work inside Task.detached(priority: .userInitiated) like repairFinding does, then hop back to the main actor only for the driftScan/state mutation. Update the DriftReviewSheet buttons to call them inside a Task.
- **Effort:** M

### M90 — goodCopyURL re-reads every drive's full manifest per finding in repair loops

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1289`, `Sources/OpenPhotoApp/AppState.swift:1298`, `Sources/OpenPhotoApp/AppState.swift:1300`, `Sources/OpenPhotoApp/AppState.swift:1183`, `Sources/OpenPhotoApp/AppState.swift:1273`, `Sources/OpenPhotoApp/AppState.swift:1279`
- **Problem:** goodCopyURL(forHash:excluding:) loops over every connected durable drive and, for each, does Manifest.read(full file) followed by a linear .first(where: { $0.hash == hash }) scan. It is called once per finding from restoreOne (restoreAllRecoverable loop) and repairFinding (repairAllRecoverable loop, also ConsensusRepairSheet.repairEverything). Net cost for repairing N findings across D drives is O(N × D × manifestSize) of disk reads + JSON parsing + linear search, repeating the exact same per-drive manifest parse for every finding.
- **Suggested fix:** Build a hash → URL index once per repair batch: read each connected drive's manifest a single time into a [hash: (drive, relPath)] dictionary (canonical-first), then look up each finding in O(1). Pass that index into the per-finding repair calls instead of re-deriving it each time.
- **Effort:** M

### M91 — BinStore.moveToBin/restore silently no-op when destination already occupied; failures swallowed at call sites

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/BinStore.swift:21`, `Sources/OpenPhotoCore/Vault/BinStore.swift:27`, `Sources/OpenPhotoCore/Vault/BinStore.swift:42`, `Sources/OpenPhotoCore/Vault/BinStore.swift:47`, `Sources/OpenPhotoCore/LibraryService.swift:310`, `Sources/OpenPhotoApp/Bin/BinView.swift:40`
- **Problem:** moveToBin moves src -> bin/relPath with `fm.moveItem`. If a file with the same relPath was previously binned (e.g. a path re-created after deletion and deleted again), the bin destination already exists and moveItem throws 'fileExists'. The delete caller (LibraryService.swift:310) swallows this with `catch { continue }`, so the user's delete silently fails for that item with no UI feedback. Symmetrically, restore moves bin/relPath -> live path; if a new file now occupies that live path, moveItem throws, and BinView calls `try? await state.library?.restore(entry)` (BinView.swift:40), so the Restore button does nothing and shows no error. Neither path overwrites (so no data loss), but the operations silently fail, which users will hit and be confused by.
- **Suggested fix:** Make the bin collision-safe: when moving into the bin, derive a collision-free destination (reuse FileNaming.collisionFreeURL) and store that adjusted path in the BinItem. For restore, detect an occupied live path and surface a clear error / offer to restore alongside (collision-free) rather than swallowing with try?. Propagate the error to the UI so the user knows the delete/restore did not happen.
- **Effort:** M

### M92 — Manifest/BinStore JSONL parse aborts entire file on a single malformed line

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/Manifest.swift:60`, `Sources/OpenPhotoCore/Vault/Manifest.swift:62`, `Sources/OpenPhotoCore/Vault/BinStore.swift:62`, `Sources/OpenPhotoCore/Vault/BinStore.swift:63`
- **Problem:** Both readers split on 0x0A and `.map { try decoder.decode(...) }`. A single corrupt/truncated line (e.g. from a write interrupted on a less-durable path, a partially-flushed sidecar, or external tampering) makes the whole read throw, so the entire manifest or bin log becomes unreadable rather than degrading gracefully. Given the JSONL format was explicitly chosen for line-level resilience, an all-or-nothing decode defeats that property; a manifest that fails to load can block the vault from opening or cause a rescan to treat every cataloged file as new.
- **Suggested fix:** Decode lines defensively: skip (and optionally log/quarantine) lines that fail to decode rather than throwing for the whole file, so one bad line cannot take down the manifest/bin. If strictness is required, surface the count of dropped lines to the caller.
- **Effort:** S

### M93 — One malformed line makes the whole manifest / bin log unreadable, and callers silently treat it as empty

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/Manifest.swift:60-62`, `Sources/OpenPhotoCore/Vault/BinStore.swift:62-63`, `Sources/OpenPhotoApp/AppState.swift:709-710`, `Sources/OpenPhotoApp/AppState.swift:959`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:146`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:136`
- **Problem:** Both Manifest.read and BinStore.list() do `data.split(0x0A).filter{!isEmpty}.map { try decoder.decode(...) }`. The `map` rethrows on the FIRST line that fails to decode, so a single truncated/garbled line (partial write of a non-atomic third-party writer, disk error, a stray byte) makes the ENTIRE manifest or bin log throw. That alone would be acceptable as a loud failure, but a large fraction of call sites wrap the read in `try? Manifest.read(...) ?? []` (AppState 709/710/959, ImportEngine 146, SyncEngine 136, ForeignVaultSource, CatalogSnapshot, etc.). The combination silently degrades a vault with one bad line into an apparently EMPTY vault: the importer sees zero known hashes (re-imports everything / mis-dedupes), drift/diff logic sees an empty inventory, and the bin view shows nothing recoverable. The format spec (§4) says readers should let the filesystem win for existence and treat the manifest as a reconstructible inventory claim — the all-or-nothing parse plus `?? []` violates that intent. The bin log is worse: it is the only record of what is recoverable, and it is not reconstructible.
- **Suggested fix:** Parse per-line tolerantly: skip (and ideally log/count) lines that fail to decode instead of aborting the whole file — e.g. `data.split(0x0A).compactMap { try? decoder.decode(...) }`, returning the salvageable entries. For the bin specifically, prefer surfacing a non-fatal warning over silently dropping recoverable items. Audit the `try? read() ?? []` sites so a genuine read error is distinguishable from a legitimately empty vault.
- **Verification:** The parse defect is real: Manifest.read (Manifest.swift:60-62) and BinStore.list (BinStore.swift:62-63) both use `.map { try decode }`, so a single malformed line throws the whole file, and most manifest callers swallow it via `try? ... ?? []` (AppState 709/710/959, SyncEngine 136, ImportEngine 146), conflating read-error with empty — which does contradict the spec's "manifest is reconstructible / filesystem wins" intent (§4, line 87-89). However the consequences are overstated: the importer's actual dedup uses `library.catalog.hashPresent` (SQLite), not the manifest, so a bad manifest line does NOT cause re-import/mis-dedupe; the manifest read at ImportEngine:146 is only a post-placement verification (files already safely on disk); and BinStore.list()'s only consumer (LibraryService:342) uses `try`, not `try?`, so a bad bin line throws loudly rather than silently showing an empty bin, and the bin files themselves still physically exist — hence Medium, not High. (Severity adjusted from High to Medium on verification.)
- **Effort:** S

### M94 — Collision-adjusted move recomputes relPath via symlink-resolving relativePath(), risking a bogus absolute manifest path

- **Severity:** Medium
- **Confidence:** Suspected
- **Category:** file-integrity
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:79`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:80`, `Sources/OpenPhotoCore/Vault/Vault.swift:29`, `Sources/OpenPhotoCore/Vault/Vault.swift:31`
- **Problem:** On a destination collision, moveFile recomputes the relative path with `vault.relativePath(of: dstURL)`. relativePath resolves symlinks on BOTH the vault root and the URL (Vault.swift:30-31) and, when the resolved path does not start with rootPath + '/', returns the FULL ABSOLUTE path instead of a relative one (Vault.swift:32). dstURL here is freshly built under dstDirURL (an in-vault directory) so it normally resolves cleanly, but if the vault root contains a symlinked component that resolves differently than the constructed child path (e.g. a relocated library, a /Volumes mount, or a firmlink), the prefix check can fail and an absolute path gets written into the manifest as if it were vault-relative (rewriteManifestEntry, line 92/80). That corrupts the manifest and any later absoluteURL(forRelativePath:) lookup.
- **Suggested fix:** Avoid the round-trip through symlink resolution: compute the collision-adjusted relPath by string-appending the collision-free basename to the already-known dst directory (dstDir + '/' + dstURL.lastPathComponent) instead of calling vault.relativePath(of:). Alternatively, have relativePath throw / assert rather than silently returning an absolute path when the prefix check fails.
- **Effort:** S

### M95 — Bin log is fully re-parsed and rewritten on every single delete/restore (O(N^2) batches) with no caching

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/BinStore.swift:36-39`, `Sources/OpenPhotoCore/Vault/BinStore.swift:55`, `Sources/OpenPhotoCore/Vault/BinStore.swift:70-76`, `Sources/OpenPhotoCore/LibraryService.swift:306-320`, `Sources/OpenPhotoCore/LibraryService.swift:338-348`, `Sources/OpenPhotoApp/AppState.swift:1544`
- **Problem:** moveToBin (line 36-39) reads + JSON-parses the ENTIRE bin log via list(), appends one item, then writeLog re-encodes the WHOLE list and does a full atomic temp+fsync+rename. LibraryService.delete loops moveToBin per item (306-320), so binning N photos is N reads + N full re-encodes + N fsyncs of a log that grows to N entries — O(N^2) work and N fsyncs for one user gesture. Independently, binItems() (338-348) re-reads and re-parses every vault's bin log from disk every time it is called, and AppState.refreshQueries() (1544) calls it; refreshQueries is invoked from ~24 sites (after every delete, restore, move, sync, scan). There is no in-memory cache, so the main-actor refresh repeatedly hits disk to recompute a list that rarely changed.
- **Suggested fix:** Make moveToBin append a single line to bin.jsonl (open-for-append + fsync) instead of read-modify-rewrite, reserving the full atomic rewrite for restore/compaction. Cache binItems() results in LibraryService (invalidate on delete/restore/emptyBin) so refreshQueries doesn't re-parse every bin log on unrelated refreshes.
- **Effort:** M

## Low

### L01 — loadPeople / loadCullGroups / runSearch have no generation guard — a stale async result can overwrite a newer one

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** concurrency
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:208`, `Sources/OpenPhotoApp/AppState.swift:224`, `Sources/OpenPhotoApp/AppState.swift:245`, `Sources/OpenPhotoApp/AppState.swift:290`, `Sources/OpenPhotoApp/AppState.swift:476`, `Sources/OpenPhotoApp/AppState.swift:521`
- **Problem:** These start a Task without cancelling any in-flight predecessor and without a request token. If invoked twice in quick succession (e.g. cullMode flips bursts->duplicates, or the search query changes, or facesDirty re-triggers loadPeople mid-flight), two detached computations run and whichever finishes LAST wins — which may be the older/slower one, leaving cullGroups/searchResults/people showing results for a superseded input. loadCullGroups also sets cullLoading=true twice and clears it on each completion, so the spinner can drop while a newer compute is still running.
- **Suggested fix:** Store the Task handle (e.g. searchTask, cullTask, peopleTask), cancel() it at the top of each method before starting a new one, and/or capture a monotonically increasing token at start and only publish results if the token still matches the latest. closeLibrary should also cancel these handles.
- **Effort:** S

### L02 — God object: AppState concentrates library, queries, watchers, derivation, drives, search, people, cull, send and undo in one ~1740-line @MainActor type

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:51`, `Sources/OpenPhotoApp/AppState.swift:1316`, `Sources/OpenPhotoApp/AppState.swift:1473`, `Sources/OpenPhotoApp/AppState.swift:1531`, `Sources/OpenPhotoApp/AppState.swift:813`
- **Problem:** All app subsystems share one mutable @MainActor object. The consequences are concrete on this lens: (1) it is the natural home for the main-thread DB/FS work flagged above; (2) lifecycle correctness depends on closeLibrary remembering to reset ~20 stored properties and 4 DeviceWatcher closures by hand (comments literally say 'MUST-FIX: reset cached objects' — easy to miss one when a new feature adds state, causing cross-library bleed); (3) every feature can mutate every other feature's state, making the stale-result and lifecycle races above hard to reason about. This is the root enabler of the other findings rather than a standalone bug.
- **Suggested fix:** Extract cohesive coordinators (DrivesCoordinator, DerivationRunner, SearchController, PeopleStore) each owning their own tasks/state with explicit start/cancel lifecycles, leaving AppState as a thin composition root. This makes closeLibrary a set of coordinator.tearDown() calls instead of a hand-maintained reset list, and localizes the off-main work.
- **Effort:** L

### L03 — Concurrent people-management ops have an unserialized read-modify-write window on a shared sidecar

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** file-integrity
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:300`, `Sources/OpenPhotoApp/AppState.swift:316`, `Sources/OpenPhotoApp/AppState.swift:333`, `Sources/OpenPhotoApp/AppState.swift:351`, `Sources/OpenPhotoApp/AppState.swift:382`, `Sources/OpenPhotoApp/AppState.swift:441`, `Sources/OpenPhotoApp/AppState.swift:470`
- **Problem:** nameCluster/mergePeople/splitFaces/reassignFace/removePerson each spawn an independent Task.detached and, off-main, call rewriteSidecarForHash, which does read sidecar -> merge regions -> write sidecar. Nothing serializes two of these against each other. If two ops touch overlapping asset hashes concurrently, their read-modify-write can interleave (A reads, B reads, A writes, B writes) and B's write loses A's change. The individual write is atomic, and rewriteSidecarForHash re-derives confirmed faces from the (dbQueue-serialized) catalog so the final on-disk state usually re-converges to catalog truth — but there is a genuine lost-update window for the addRegions path, and the human-authored region data in the XMP sidecar is exactly the kind of data the format docs treat as authoritative.
- **Suggested fix:** Serialize sidecar mutations: route all people-management writes through a single dedicated serial executor/actor (or an async queue keyed by hash), or always re-read+rewrite strictly from catalog state under a per-hash lock so concurrent ops can't clobber each other's region merge.
- **Effort:** M

### L04 — tagsForSave / runSearch / structuredFilter feed unvalidated external metadata into search and sidecars

- **Severity:** Low
- **Confidence:** Needs verification
- **Category:** security
- **Subsystem:** AppState (god object)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:120`, `Sources/OpenPhotoApp/AppState.swift:134`, `Sources/OpenPhotoApp/AppState.swift:476`, `Sources/OpenPhotoApp/AppState.swift:466`
- **Problem:** Several paths flow externally-controlled strings (asset tagsJSON decoded from the catalog/sidecars at line 134, person names and file-derived rects used to build sidecar dedupe keys at line 466, and free-text search query passed to catalog.textMatches/structuredFilter at 498/491) without explicit validation in AppState. Whether these are injection-safe depends entirely on the Catalog/SidecarStore layer (parameterized SQL, XML escaping). This file does not itself sanitize; if any downstream uses string interpolation into SQL/XML it would be exploitable via crafted XMP/Takeout content. I could not fully confirm the downstream safety from AppState alone.
- **Suggested fix:** Verify Catalog.textMatches/structuredFilter and SidecarStore.write use bound parameters and proper XML escaping (the FTS path at Catalog+Derivation.swift:90 does escape quotes, which is a good sign). If confirmed safe, no change here; if any interpolation exists, fix at the Catalog/Sidecar layer. Out of strict scope for this file but worth a cross-layer check given untrusted XMP/Takeout input.
- **Effort:** S

### L05 — refreshQueries auto-expands the entire folder tree whenever expandedFolders is empty

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:1536-1543`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:287`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:359`
- **Problem:** refreshQueries treats an empty `expandedFolders` as 'first load' and re-expands every node in the tree. But empty is also a legitimate user/runtime state: deleteFolder (line 287) filters expandedFolders and can legitimately reduce it to empty (e.g. the user had collapsed everything and deletes the last expanded branch), and remapUIPaths (line 359) rebuilds the set. The next refreshQueries — fired by any later create/scan/drive-connect — then silently re-expands the whole tree, overriding the user's collapsed view. This is a surprising loss of view state rather than a crash.
- **Suggested fix:** Gate the auto-expand on an explicit 'never initialized' flag (e.g. an Optional<Set<String>> or a `didInitialExpand` bool) instead of inferring first-load from emptiness, so a deliberately-empty expansion set is respected.
- **Effort:** S

### L06 — applyUndo's isApplyingUndo flag can suppress a legitimate concurrent recordUndo

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** concurrency
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+Undo.swift:14`, `Sources/OpenPhotoApp/AppState+Undo.swift:26`, `Sources/OpenPhotoApp/AppState+Undo.swift:27`, `Sources/OpenPhotoApp/AppState+Undo.swift:64`, `Sources/OpenPhotoApp/AppState+Undo.swift:65`
- **Problem:** applyUndo sets isApplyingUndo = true for the whole duration of the replay, which for .movePhotos/.moveFolder includes `await movePhotos(...)`/`await moveFolder(...)` that themselves `await rescan()`. Because everything is on the MainActor, those awaits yield and let an unrelated user-initiated action run; any recordUndo it issues during that window is silently dropped by the `guard !isApplyingUndo` at line 15, so that user action becomes non-undoable. This is the intended mechanism for suppressing redo of the *replayed* ops, but it over-broadly suppresses genuinely new actions that interleave during the long await. Narrow window and requires precise timing, hence Low.
- **Suggested fix:** Scope the suppression tightly: set/clear isApplyingUndo only around the synchronous re-dispatch (or pass an explicit "suppress recording" flag through to the replayed op) rather than holding it across the replayed op's own rescan() await. Alternatively gate user input while an undo replay is in flight.
- **Effort:** M

### L07 — Drive-relpath and parent-path mapping logic is triplicated

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:23-25`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:45-47`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:365-367`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:369-371`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:14-18`
- **Problem:** The basename-prefix mapping exists as instance method `mapToDrive(_:basename:)` (line 23) AND as free function `mapToDriveStatic(_:basename:)` (line 365) with byte-identical bodies; likewise `parentRelPath(of:)` (line 45) duplicates `parentOf(_:)` (line 369). The header comment (lines 14-18) further notes this is a hand-inlined copy of the internal `SyncEngine.driveRelPath(forSourceVault:relPath:)`. Three copies of a path-canonicalization rule that must stay byte-for-byte consistent (NFC normalization is correctness-critical for cross-drive path matching) is a divergence hazard: a future fix to one (e.g. handling a trailing slash, or a different normalization form) silently desyncs the others, producing drive paths that no longer match manifest/presence rows.
- **Suggested fix:** Promote `SyncEngine.driveRelPath(forSourceVault:relPath:)` (and its inverse) to public in OpenPhotoCore and call it from both the @MainActor methods and the detached closures, deleting all four local copies. If the @MainActor-vs-detached split blocks reuse, at minimum have `mapToDrive`/`parentRelPath` forward to the free functions so there is one body.
- **Effort:** S

### L08 — recordUndo reconfigures levelsOfUndo on every registration

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+Undo.swift:16`
- **Problem:** `um.levelsOfUndo = 50` is assigned inside recordUndo, so it runs on every single undoable action rather than once when the window's UndoManager is captured. It's a harmless redundancy but conflates one-time configuration with per-action recording, and obscures where the undo budget is actually configured.
- **Suggested fix:** Set levelsOfUndo once where windowUndoManager is assigned (RootView capture) and drop it from the hot path.
- **Effort:** S

### L09 — Per-drive x per-file nested propagation loops on the main path

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** AppState extensions (folder reorg, undo)
- **Location:** `Sources/OpenPhotoApp/AppState+FolderReorg.swift:134-140`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:143-148`
- **Problem:** movePhotos propagates with a connected-drives x moved-files double loop for the disk moves (lines 134-140) and again for offline enqueue (lines 143-148). For a large multi-select move (thousands of photos) across several registered drives this is O(drives x files) FileManager/catalog calls. The disk work is correctly off-main via Task.detached, but the offline `enqueueFolderOp` loop (lines 143-148) runs on @MainActor and issues one catalog write per (drive x file), which can stall the UI for a large selection while many drives are offline.
- **Suggested fix:** Batch the offline enqueue into a single transaction per drive (one catalog call taking the whole move list) rather than a write per file; this also reduces the partial-failure surface flagged in the error-swallowing finding.
- **Effort:** M

### L10 — purgeLocalVault does not clear pending_folder_ops queued against the purged vault

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog.swift:246-260`, `Sources/OpenPhotoCore/Catalog/Catalog+FolderOps.swift:16-50`
- **Problem:** purgeLocalVault removes the vault registration, its instances, its presence rows, and orphaned per-hash data, but never deletes pending_folder_ops rows whose vaultID equals the purged vault. Those become dangling queued structural ops referencing a vault that no longer exists. In practice folder ops are enqueued for offline drives rather than the local vault, so the local-purge path may never have such rows — hence Suspected/Low — but if a drive vault is ever fed through this path (or a vault id is reused), stale ops could replay against the wrong target.
- **Suggested fix:** Add `try db.execute(sql: "DELETE FROM pending_folder_ops WHERE vaultID = ?", arguments: [id])` inside the purgeLocalVault (and unregisterVault) write block — there is already a clearFolderOps(forVault:) helper expressing exactly this delete.
- **Effort:** S

### L11 — setCanonical/setVaultLastSeen UPDATE-by-id silently no-op on a missing id; setCanonical can leave zero canonicals

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog.swift:214-231`
- **Problem:** setCanonical runs `UPDATE vaults SET role='canonical' WHERE id = ?` with no check that any row matched. If `newID` is not a registered vault (typo, stale id, race with unregisterVault), the update affects 0 rows and the optional demote of oldID still fires, so the catalog can end up with zero canonical vaults despite the doc-comment guaranteeing 'never momentarily zero or two canonicals'. setVaultLastSeen has the same no-match-is-silent property (lower stakes). No user-facing error surfaces because GRDB execute() does not error on 0 affected rows.
- **Suggested fix:** After the canonical UPDATE, check db.changesCount == 1 (or SELECT EXISTS first) and throw a typed error if newID isn't present, so the caller can surface it rather than silently dropping the library's canonical designation.
- **Effort:** S

### L12 — Dead eligibleKind(forStage:) switch — every branch returns the same value

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift:9`
- **Problem:** eligibleKind(forStage:) is a five-case switch plus default where ocr/embed/faces/geocode/phash and the default all return "photo". It reads as if stages map to different kinds, but it is effectively a constant. The branching is dead code that misleads a reader into thinking video stages are handled differently, and the `default: return "photo"` would silently mis-bucket any future video-only stage.
- **Suggested fix:** Replace with `return "photo"` (or a named constant) until a stage genuinely needs a different kind, at which point reintroduce real cases with no permissive default.
- **Effort:** S

### L13 — Float16 pack/unpack helpers duplicated verbatim across two files

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:6`, `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:11`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:30`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:35`
- **Problem:** packFloat16/unpackFloat16 (Catalog+Embeddings) and packF16/unpackF16 (Catalog+Faces) are byte-identical Float16 little-endian encode/decode logic, duplicated only because both are declared `private static` in their own extension. The in-code comment even acknowledges the duplication ("mirrors Catalog+Embeddings.swift's private helpers — kept private here to avoid collision"). Any change to the on-disk vector encoding (the format docs call this normative) must be made in two places, risking the two blob encoders silently diverging.
- **Suggested fix:** Hoist a single internal helper pair (e.g. `Catalog.packFloat16/unpackFloat16` or a free function in a Vectors.swift) and call it from both extensions. Since both vector blobs are the same on-disk format, one shared implementation is also the right place to keep that format contract.
- **Effort:** S

### L14 — Long face column-list SQL duplicated across three fetch methods

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:85`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:98`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:106`
- **Problem:** The identical 11-column projection `id, hash, rectX, rectY, rectW, rectH, embedding, dim, personID, confidence, source` is hand-written three times (face(forID:), faces(forHash:), faces(forPerson:)), all feeding the same faceRow(from:) decoder. A column rename or addition must be edited in lockstep across three string literals, and a missed one fails only at runtime via Row subscript. Note also the inconsistency: face(forID:) lays the list across multiple lines while the other two cram it onto one long line.
- **Suggested fix:** Extract a single `static let faceColumns` (or a shared `SELECT ... FROM faces` prefix) and interpolate it into the three queries' WHERE clauses, so the projection and the faceRow(from:) decoder stay in one-to-one correspondence.
- **Effort:** S

### L15 — Stale doc comment: representativeFaceID is not filtered to confirmed faces

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:24`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:140`
- **Problem:** PersonRow.representativeFaceID is documented as "highest-confidence confirmed face", but the people() fallback subquery is `SELECT f2.id FROM faces f2 WHERE f2.personID = p.id ORDER BY f2.confidence DESC LIMIT 1` with no `source = 'confirmed'` filter. The representative can therefore be an auto (unconfirmed) face. The comment overstates the guarantee, which matters because the value drives the cover thumbnail shown on the People screen.
- **Suggested fix:** Either correct the comment to "highest-confidence face (any source)" or add `AND f2.source = 'confirmed'` to the fallback if a confirmed cover is actually wanted (with a secondary fallback so a never-confirmed person still gets a cover).
- **Effort:** S

### L16 — All Catalog reads are synchronous DB calls; several SwiftUI consumers run them on the main actor

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Catalog & schema
- **Location:** `Sources/OpenPhotoCore/Catalog/Queries.swift:33`, `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift:133`, `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift:40`, `Sources/OpenPhotoApp/Search/ProFilterBar.swift:38`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:230`
- **Problem:** The Catalog read API is entirely synchronous (dbQueue.read), which is fine for the layer itself, but it offers no async variants and so invites main-thread blocking at the call site. Unlike the heavy paths (MapView/loadPeople/cull) which correctly hop to Task.detached, the filter bars run people()/distinctPlaces()/distinctTags() directly inside a default `.task {}` (main actor), and InspectorView runs loadFaces() (faces(forHash:) + people()) inside `.task(id:)` on the main actor. people() does a per-row correlated-subquery GROUP BY across all faces; on a large library these block UI for the duration of the read.
- **Suggested fix:** Either provide async wrappers on Catalog (e.g. `func peopleAsync() async throws` that does the read on a background executor) or, minimally, wrap the filter-bar/inspector loads in Task.detached as the Map/People-overview paths already do. This is primarily a consumer-side fix, but a thin async surface on Catalog would make the correct usage the easy one.
- **Effort:** M

### L17 — BurstGrouper chains consecutive frames so a slow pan exceeds the intended 60s window

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Cull/BurstGrouper.swift:13`, `Sources/OpenPhotoCore/Cull/BurstGrouper.swift:15`, `Sources/OpenPhotoCore/Cull/BurstGrouper.swift:16`, `Sources/OpenPhotoCore/Cull/BurstGrouper.swift:17`
- **Problem:** The gap is measured to the PREVIOUS frame (`current[count-1]`), not the burst's first frame, and similarity is also only vs the immediate predecessor. A sequence of frames each <=60s apart and each cosine>=0.93 vs its neighbor chains indefinitely, so a slow continuous shoot can put photos minutes apart into one 'burst', and gradual scene drift (A~B, B~C, but A not ~C) lands A and C in the same group though they are dissimilar. This is the same chaining class flagged for FaceClusterer; here the blast radius is small (it only groups true bursts for keeper suggestion, the user reviews before deleting) so severity is Low, but the grouping semantics are not what the doc ('a burst') implies.
- **Suggested fix:** If strict bursts are desired, also bound the total span (gap to the FIRST frame of `current`) and optionally compare similarity to the group anchor, not just the predecessor. Otherwise document that grouping is transitive-chained by design.
- **Effort:** S

### L18 — Float16 unpack truncates short blobs to a wrong-length vector instead of failing

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:11`, `Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift:15`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:34`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:87`
- **Problem:** unpackFloat16 reads `min(dim, halves.count)` floats. If the stored `dim` column and the actual blob length disagree (truncated/corrupt write, or a partially-written embedding), the returned vector silently has fewer elements than `dim`. FaceClusterer then treats `item.vector.count` as the dim; two faces with the same TRUE identity but different truncation lengths get `cosineDistance == .infinity` (dim guard) and never merge — a silent clustering miss rather than a crash. BurstGrouper.dot guards `a.count == b.count` and returns 0, similarly degrading silently. No crash, but the data-integrity assumption (blob length == dim*2) is never validated on read.
- **Suggested fix:** In unpackFloat16, assert/return nil when `halves.count < dim` (or `data.count != dim*2`) so a corrupt embedding surfaces as a skipped/failed row rather than a silently short vector. Given hash-verified-copy invariants, embeddings are rebuildable, so dropping a bad one and re-deriving is safe.
- **Effort:** S

### L19 — Duplicated tiebreaker logic and magic thresholds across the cull algorithms

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Cull/KeeperSelector.swift:25-37`, `Sources/OpenPhotoApp/AppState.swift:255`, `Sources/OpenPhotoApp/AppState.swift:260`, `Sources/OpenPhotoApp/AppState.swift:265`, `Sources/OpenPhotoCore/Faces/FaceClusterer.swift:11-13`
- **Problem:** KeeperSelector's max(by:) repeats the pixelCount/fileSize/hash tiebreaker chain across two branches with subtle ordering (the 'a < b' comparator inverted for max is easy to get wrong). Separately, the operative thresholds live as inline magic numbers at the call site in AppState (burst windowMs 60_000 / cosine 0.93; duplicate hamming 2; similar hamming 6) rather than as named, documented constants near the algorithms they tune, while the face threshold default is documented in FaceClusterer's header but actually set as a private let in AppState (203). The tuning knobs that define product behaviour are scattered between doc comments and call sites, making them hard to keep consistent and to expose via the 'future UI control' the docs promise.
- **Suggested fix:** Centralize the cull/burst/face thresholds as named constants (e.g. a CullTuning enum in OpenPhotoCore) referenced by both the algorithms' docs and AppState. In KeeperSelector, extract the comparison into a single keyed ordering (e.g. compare tuples) to remove the duplicated, easy-to-invert branch.
- **Effort:** S

### L20 — EmbedStage allocated solely to read a constant modelID in the cull path

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoApp/AppState.swift:254`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:17`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:44-46`
- **Problem:** loadCullGroups() calls EmbedStage().modelID just to obtain the model identifier string for embeddingsWithTakenAt(model:). EmbedStage is a heavier CoreML wrapper class; instantiating it (even though init only sets modelDirectory, so it's cheap) to read a constant is a leaky abstraction and couples the cull/burst query to the embed stage's lifecycle. It also means the source-of-truth for the model id is an instance member rather than a type-level constant.
- **Suggested fix:** Expose the model id as a static constant (e.g. EmbedStage.defaultModelID) and reference that, or thread the model id through from wherever embeddings were written so bursts query the same model without constructing an EmbedStage.
- **Effort:** S

### L21 — DuplicateGrouper union-find lacks path compression / union-by-rank and is O(n^2) per folder

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Cull & Faces (clustering/dedup)
- **Location:** `Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift:15-23`, `Sources/OpenPhotoApp/AppState.swift:259-265`
- **Problem:** Within each folder bucket the code compares all pairs (for i; for j in i+1..<count) = O(m^2) Hamming computations, and the union-find find() walks the parent chain without path compression while union() does parent[find(a)]=find(b) without union-by-rank. For a folder containing thousands of phash rows (a single big dump folder is common) this is quadratic plus degenerate-tree find costs. It runs off-main so it won't freeze the UI, but it scales poorly on exactly the kind of folder users run Duplicates over.
- **Suggested fix:** Add path compression in find() (point each visited node at the root) and union-by-rank/size; for the pairwise scan, bucket by phash prefix or sort to prune comparisons. Even just path compression removes the degenerate-chain cost cheaply.
- **Effort:** M

### L22 — gunzip output buffer sized from gzip ISIZE field truncates silently if the stream is larger

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift:276`, `Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift:278`, `Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift:281`, `Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift:286`
- **Problem:** `gunzip` reads ISIZE (the trailing 4 bytes) as the destination capacity. ISIZE is the uncompressed size MODULO 2^32 per RFC 1952, and `compression_decode_buffer` returns only the bytes that fit the destination WITHOUT signaling overflow. If the gzipped vocab ever exceeded ~4GB, or ISIZE were corrupt/small (and the `isize > 0 ? isize : bytes.count*8` fallback still under-sizes), the inflate would be silently truncated; `decoded > 0` still passes, the UTF-8 decode of a truncated buffer may still succeed, and the tokenizer would initialize with a partial merge table — producing wrong token ids with no error. Harmless for today's fixed ~1.3MB vocab, but a latent correctness trap with no guard against truncation.
- **Suggested fix:** Loop or grow the destination on a full/truncated result, or validate the decoded length against an independent expectation. Practically: if `decoded == capacity` (buffer exactly filled), treat it as a possible truncation and retry with a larger buffer; or use a streaming `compression_stream` so the full output is captured regardless of ISIZE. At minimum assert the parsed merge count equals the expected 48894 before trusting the tokenizer.
- **Effort:** M

### L23 — modelID resolved via throwaway EmbedStage() at several call sites — duplicated, fragile constant access

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoApp/AppState.swift:254`, `Sources/OpenPhotoApp/AppState.swift:503`, `Sources/OpenPhotoApp/AppState.swift:1350`
- **Problem:** Three sites construct `EmbedStage()` purely to read `.modelID` (a constant string "mobileclip_s2"). These constructions are cheap today only because the lazy model/tokenizer load hasn't been triggered, but it couples 'what string identifies the embedding model' to constructing a whole inference object, and it is easy to accidentally call an expensive method on one of these throwaways (as line 510 effectively does for embedText). It also scatters the model identity across the file instead of one source of truth.
- **Suggested fix:** Expose the model id as a `static let modelID` on EmbedStage (or a free constant) and reference that directly, and/or route these through the single shared EmbedStage instance proposed in the search-recreation finding. Removes three object constructions and centralizes the identifier.
- **Effort:** S

### L24 — EmbedStage and PHashStage/Face decode the source at full resolution before downsizing

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** memory
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:162`, `Sources/OpenPhotoCore/Derivation/EmbedStage.swift:163`
- **Problem:** EmbedStage.makePixelBuffer decodes the full-resolution CGImage via CGImageSourceCreateImageAtIndex (no thumbnail/downsample options) and only then scales it into the 256x256 pixel buffer (EmbedStage:189-194). For a 50MP source that fully decodes ~200MB of RGBA before throwing nearly all of it away. PerceptualHash already does the right thing (CGImageSourceCreateThumbnailAtIndex with maxPixelSize 64); EmbedStage does not. Combined with the missing autoreleasepool (separate finding) this is the dominant transient allocation per embed job over the 42k run. FaceStage genuinely needs the full image for accurate crops, so it is excluded, but Embed only needs a 256px center-crop.
- **Suggested fix:** In EmbedStage.makePixelBuffer(from url:), use CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize set to ~the target side (and kCGImageSourceCreateThumbnailFromImageAlways / WithTransform) to bound the decoded bitmap before the center-crop draw, mirroring PerceptualHash. Confirm the aspect-fill center-crop math still holds when the source is pre-shrunk.
- **Effort:** S

### L25 — GeoNamesLoader holds the full city table in RAM with no lifecycle bound

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** memory
- **Subsystem:** Derivation / ML pipeline
- **Location:** `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:46`, `Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift:48`, `Sources/OpenPhotoCore/Geocode/ReverseGeocoder.swift:30`, `Sources/OpenPhotoCore/Geocode/ReverseGeocoder.swift:31`, `Sources/OpenPhotoCore/Derivation/GeocodeStage.swift:18`
- **Problem:** `GeoNamesLoader.load` reads the entire cities15000.txt into a String (String(contentsOf:)) and builds a ~30k-element [City] array (struct with 4 Strings + 2 Doubles) plus a [GridKey:[Int]] index, all held for the lifetime of the GeocodeStage's ReverseGeocoder. cities15000 is bounded (~30k rows, a few MB) so this is modest, but: (a) the whole file is materialized as one String during parse (transient spike), and (b) GeocodeStage is created inside the derivationStages array (AppState.swift:1457) and lives for the whole app session, so the table never releases even when geocoding is idle. Acceptable for the 15000-population cutoff file, but worth noting as an always-resident table given the subsystem's memory sensitivity.
- **Suggested fix:** Acceptable as-is for cities15000. If a larger GeoNames extract is ever bundled, stream the file line-by-line instead of one String(contentsOf:), and consider lazily constructing the geocoder on first geocode job and tearing it down when the geocode stage's pending set drains, rather than holding it for the whole session.
- **Effort:** M

### L26 — Empty-trash button label/count is read at a different time than the delete confirmation

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:88`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:120`, `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:195`
- **Problem:** The 'Permanently delete N trashed item(s)…' button and its confirmation dialog both render `trashCount`, but runEmptyTrash() calls `source.emptyTrash()` which removes the entire `.openphoto-trash` directory (VolumeSource.emptyTrash) regardless of the displayed count. If new items are trashed (via runDelete refreshing trashCount) between the dialog appearing and confirmation, the count shown can understate what is actually permanently destroyed. Because emptyTrash is the one sanctioned hard-delete in the system, a stale/incorrect count on an irreversible action is worth tightening, even though the practical window is small.
- **Suggested fix:** Re-read the trash count immediately before presenting the confirmation (or snapshot the exact item set to delete and delete only that set), so the irreversible action's displayed magnitude always matches what is removed.
- **Effort:** S

### L27 — ICDeviceTypeMask force-unwrap on a hardcoded raw mask

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:75`
- **Problem:** `browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x00000001 | 0x00000100)!` force-unwraps an ICDeviceTypeMask built from a hardcoded raw value during start(). If a future SDK revision changes the valid bit set so this raw value no longer maps to a non-nil OptionSet/struct (or the initializer becomes failable in a stricter way), start() traps and the whole device-watching subsystem crashes at library open. The bits are magic numbers (camera + scanner type masks) rather than the named ImageCaptureCore constants.
- **Suggested fix:** Use the named constants and avoid the force-unwrap: `browser.browsedDeviceTypeMask = [.camera]` (ICDeviceTypeMask is an OptionSet), or if the raw form is required, guard it: `if let mask = ICDeviceTypeMask(rawValue: ...) { browser.browsedDeviceTypeMask = mask }`.
- **Effort:** S

### L28 — source! force-unwrap in import grid relies on an implicit phase invariant

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:139`
- **Problem:** ImportTile is built with `source: source!` inside importGrid. This is safe today only because `content` renders importGrid solely in the `.ready`/`.importing` phases and connect() assigns `source` before setting `.ready`. The invariant is implicit and fragile: any future change that can leave `source == nil` while phase is `.ready`/`.importing` (e.g. clearing source on device removal while the sheet is still mounted, or a new phase transition) turns this into a crash. Note connect() does not reset `source = nil` on the failure path, so a stale non-nil source masks the risk rather than eliminating it.
- **Suggested fix:** Replace the force-unwrap with a safe bind, e.g. wrap importGrid's body in `if let source { ... }`, or pass `source` down only after an `if let` at the `content` switch site so the `!` is never needed.
- **Effort:** S

### L29 — Manual-volume detection relies on a hard-coded id-prefix string literal that duplicates the enum's id-construction

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:188`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:110`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:12`
- **Problem:** volumesChanged() decides whether to keep a .volume across a rescan with dev.id.hasPrefix("vol-manual-"). That literal couples this filter to two separate string fragments built elsewhere: ConnectedDevice.id prepends "vol-" (line 14) and addManualVolume sets the id payload to "manual-" + url.path (line 110). If either prefix is ever changed, manually-added folders silently disappear on the next mount/unmount with no compile-time error. A leaky abstraction — the watcher reaches into the enum's id encoding.
- **Suggested fix:** Add an explicit boolean (e.g. ConnectedDevice.isManualFolder or a dedicated .manualVolume case) and key the retention filter on that, rather than string-prefix matching the composed id.
- **Effort:** S

### L30 — No tests around destructive drive/device flows

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Drives & Devices UI
- **Location:** `Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift:178`, `Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift:78`, `Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift:103`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift:59`, `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift:114`, `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift:159`
- **Problem:** A repo-wide search found no test target referencing any of these views (ImportView, FreeUpPhoneView, DeletionReviewSheet, DriftReviewSheet, SyncPlanSheet, ConsensusRepairSheet, DeviceWatcher). These are precisely the irreversible-action surfaces (delete-from-device, propagate deletions to a drive bin, repair/replace files, eject/forget/promote/recover canonical). The selection->confirm->count logic (e.g. FreeUpPhoneView.runDelete deletes verifiedOnDevice.filter{selection.contains}, while the dialog title/button show selection.count — these can diverge if the live list changes between selection and confirm) has no regression coverage.
- **Suggested fix:** Even without ViewInspector, extract the count/selection/eligibility derivations (verifiedOnDevice, displayItems filtering, the chosen-deletions set) into pure helpers on the value types and unit-test them; add a test asserting the count shown equals the count actually acted on after the live list mutates.
- **Effort:** M

### L31 — FolderGridView.reload swallows catalog errors with no user-facing failure state

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Folders/FolderGridView.swift:141`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift:142`
- **Problem:** reload() does `let all = (try? lib.items(inDir:recursive:)) ?? []`. A genuine catalog read failure (DB locked/corrupt mid-operation) is silently swallowed and rendered identically to a legitimately empty folder — the toolbar shows '0 items' and the grid is blank with no error indication. This is a correctness/observability gap rather than a crash; the count and grid stay consistent (both derive from `items`), so there is no count-vs-grid mismatch here. The same swallow-to-empty pattern recurs across the People reloads (PeopleView.swift:503-505, 609-612) and the map fetches (MapView.swift:194, 290).
- **Suggested fix:** Distinguish 'query failed' from 'empty result' — capture the error and surface a lightweight inline error state (e.g. a banner with a Retry), or at minimum NSLog the failure as the AppState face/sidecar helpers already do. Not load-bearing for data integrity, but improves diagnosability of a wedged catalog.
- **Effort:** S

### L32 — People overview does not refresh when faces become dirty while already on screen

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/People/PeopleView.swift:65`, `Sources/OpenPhotoApp/People/PeopleView.swift:66`, `Sources/OpenPhotoApp/AppState.swift:1513`
- **Problem:** PeopleOverviewView.onAppear only calls loadPeople() when both state.people and state.suggestedClusters are empty. After a derivation drain sets facesDirty = true (AppState.swift:1513), nothing re-invokes loadPeople() while the People view is already mounted (onAppear won't fire again, and facesDirty is consulted only inside loadPeople). The user must navigate away and back, and even then the empty-guard can suppress the reload if any people/clusters already exist. Result: newly detected faces / new suggested clusters silently fail to appear until an unrelated trigger. This is a staleness/correctness gap, not a crash.
- **Suggested fix:** Drive the overview off facesDirty: e.g. add .onChange(of: state.facesDirty)/a token bump that calls loadPeople(), or remove the empty-guard and let loadPeople short-circuit internally when !facesDirty. Expose facesDirty (currently private) as an observable token the view can react to.
- **Effort:** S

### L33 — Pure grid-clustering math (MapView.cluster) has no unit test despite tricky float bucketing and centroid logic

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:351-390`
- **Problem:** cluster(assets:region:gridDivisions:) is a self-contained, nonisolated static function with non-obvious behavior (floor-based bucketing, min-cell clamp, centroid averaging, representative = max takenAtMs). The analogous Core clustering (FaceClusterer) is unit-tested (Tests/OpenPhotoCoreTests/FaceClustererTests.swift) but this map clustering lives in the App target and has no coverage, so regressions in bucketing/centroid (e.g. antimeridian wraparound, empty/min-cell edge cases) would go unnoticed.
- **Suggested fix:** Extract cluster (and BucketKey) into a small testable type in OpenPhotoCore (or keep in-app but make it internally visible to tests) and add unit tests for single-asset, multi-cell, min-cell-clamp, and representative-selection cases.
- **Effort:** M

### L34 — Root drop target declared twice with duplicated handling logic

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Folders/FolderTreeView.swift:27-30`, `Sources/OpenPhotoApp/Folders/FolderTreeView.swift:80-86`, `Sources/OpenPhotoApp/Folders/FolderTreeView.swift:91-101`
- **Problem:** moveToRoot drop handling is wired up twice — once on the scroll content's contentShape (lines 27-30) and once behind the header (lines 80-86) — both mutating the same rootDropTargeted state and both calling moveToRoot. It works, but the duplication means the two targets can momentarily disagree on rootDropTargeted as the pointer crosses between them, and any future change to root-drop behavior must be kept in sync in two places. Minor maintainability/leaky-abstraction nit.
- **Suggested fix:** Factor the drop modifier into a single reusable ViewModifier (or a shared closure) applied to both regions, and consider separate isTargeted flags so the header and empty-space highlights don't fight over one boolean.
- **Effort:** S

### L35 — Folder picker walks the entire folder tree on every render while in select mode

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Folders/FolderGridView.swift:193-204`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift:170-175`
- **Problem:** allFolders recursively walks state.folderTree and sorts the result, and pickerFolders rebuilds that list; both are computed properties read inside moveControls' Picker, so the full-tree walk + sort runs on every body evaluation while the selection bar is visible (which is frequent, since selection changes re-render). For large folder hierarchies this is avoidable repeated O(n log n) work per render.
- **Suggested fix:** Cache the flattened+sorted folder paths (e.g. derive once from state.folderTree into a memoized value that only recomputes when the tree changes), rather than recomputing in a computed property consumed by body.
- **Effort:** S

### L36 — Map clusters get a fresh UUID on every recluster, forcing full annotation/thumbnail rebuild on each pan-zoom

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:377`, `Sources/OpenPhotoApp/Map/MapView.swift:351-385`, `Sources/OpenPhotoApp/Map/MapView.swift:63-73`, `Sources/OpenPhotoApp/Map/MapView.swift:322-335`
- **Problem:** cluster(assets:region:) constructs every MapCluster with id: UUID(), and reclustering runs on every debounced onMapCameraChange. Because Annotation identity is keyed by cluster.id (ForEach(clusters)), each recluster yields an entirely new identity set even when the visible clusters are effectively unchanged. MapKit therefore tears down and rebuilds every AnnotationView, and each clusterBubble's ThumbnailImage re-mounts and reloads its thumbnail (the .task is keyed by cacheKey, but a brand-new view re-runs it). On a library with many geotagged photos this is a visible per-pan flash and a steady CPU/IO cost, the exact 'blank/rebuilt pin' class the thumbnail cache was meant to avoid.
- **Suggested fix:** Derive a STABLE id from the cluster's contents/cell instead of UUID(): e.g. id = the bucket key (la,lo) hashed, or the sorted representativeHash, so an unchanged cell keeps its identity across reclusters and MapKit/ThumbnailImage reuse the existing view. Make MapCluster.id deterministic from (cell, representativeHash).
- **Verification:** Confirmed structurally: cluster() builds every MapCluster with id: UUID() (line 377) and ForEach(clusters) keys Annotation identity on that UUID, so each debounced recluster yields a fresh identity set and MapKit rebuilds annotation views. But the claimed symptom (thumbnail flash / reload / blank pins) is refuted: ThumbnailImage reads the shared tileMemoryCache SYNCHRONOUSLY in body (line 30) and its .task returns early on a cache hit (line 41), both keyed by representativeHash (stable across reclusters, not the UUID) — so a re-mounted bubble renders the correct cached thumbnail on its first frame with no IO. The real cost is redundant SwiftUI/MapKit view-graph churn, not the visible flash/IO storm described, so High is inflated; Low is appropriate and the stable-id fix is a valid minor optimization. (Severity adjusted from High to Low on verification.)
- **Effort:** S

### L37 — zoomIntoCluster filters all assets with an O(n·m) array-contains lookup

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Folders, Map, People UI
- **Location:** `Sources/OpenPhotoApp/Map/MapView.swift:166-173`
- **Problem:** zoomIntoCluster computes allAssets.filter { cluster.hashes.contains($0.hash) }, where cluster.hashes is an Array; contains is linear, so this is O(allAssets × clusterHashes). On a large library with a large cluster this is wasteful on the main actor at tap time. The cluster already knows its members, so re-scanning every asset is unnecessary.
- **Suggested fix:** Build the bounding box from cluster.hashes directly via a hash→GeoAsset dictionary (built once from allAssets), or carry min/max lat-lon on MapCluster when clustering so zoomIntoCluster needs no scan at all.
- **Effort:** S

### L38 — In-flight import has no cancellation path and the engine never checks Task cancellation

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoApp/Devices/ImportView.swift:188`, `Sources/OpenPhotoApp/Devices/ImportView.swift:394`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:83`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:113`
- **Problem:** The import is launched as an unstructured detached `Task { await runBatch() }` with no stored handle, so the UI cannot cancel a long (10k-item, minutes-long over USB) import. Even if it could, ImportEngine.run never calls Task.checkCancellation()/isCancelled in its fetch or place loops, so it would run to completion regardless. There is no data-corruption consequence (staged temps are removed by defer; already-placed files are legitimate atomic-renamed imports), but the user is stuck waiting and the per-batch staging UUID dir from a still-running prior batch could coexist. This is a responsiveness/UX gap rather than a safety bug.
- **Suggested fix:** Store the import Task in @State and cancel it on a Cancel button / onDisappear; add `try Task.checkCancellation()` at the top of the fetch loop (ImportEngine.swift:83) and place loop (line 113) so cancellation stops promptly while keeping the staging-cleanup defer. Already-placed items can remain (they're verified); just stop fetching more.
- **Effort:** M

### L39 — PhotosLibrarySource resource fileSize KVC can yield 0, weakening size-based fingerprints

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:47`, `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:52`
- **Problem:** byteSize is read via the undocumented KVC key value(forKey: "fileSize") with `?? 0`. When PhotoKit doesn't expose fileSize for a resource (known to happen for iCloud-only originals not yet materialized, and for some edited/paired resources), every such item gets byteSize 0. That 0 then flows into ImportItem.byteSize and into the registry/'in-library' fingerprints (size|capture-second and name|size|takenAt). Many 0-size items collapse onto the same fingerprint, inflating false 'already imported'/'in library' signals and feeding the High finding above. It does not affect the engine's hash-based real-skip decision, which re-hashes the fetched bytes.
- **Suggested fix:** Prefer a documented source for size where possible, or after fetch use the actual on-disk file size of the copied original for the registry entry (the engine has the staged file and could record its true size). At minimum, treat byteSize 0 as 'unknown' and exclude such items from size-based dedup/delete-eligibility rather than letting 0 act as a real value.
- **Effort:** M

### L40 — Skipped-duplicate registry append and metadata-fold errors are swallowed with try?

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/ImportEngine.swift:97`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:102`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:149`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:93`
- **Problem:** registry.append is called with try? in two places (the skip path line 97 and the verified path line 149). If the atomic write of imports.jsonl fails (disk full, permissions), the import still reports success but the durable dedup memory is silently not updated — a later run re-imports the same item, and the free-up-phone flow won't list it as verified. Line 93 wraps catalog.hashPresent in `try?` so a transient catalog read error degrades to 'not a duplicate' (re-imports a true duplicate) rather than surfacing. Line 102 removeItem(try?) can leak a staged temp on failure (mitigated by the staging defer). None corrupt data; they erode the dedup/free-up guarantees quietly.
- **Suggested fix:** Treat a failed registry.append on the verified path as worth surfacing (it undermines the 'never re-import, safe-to-delete' contract): either propagate into BatchResult.failed or log prominently. For hashPresent, distinguishing a read error from a genuine absence avoids silently re-importing on transient DB issues.
- **Effort:** S

### L41 — Takeout JSON matching misses truncation combined with the (n) counter and double-extension variants

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift:9`, `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift:17`, `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift:27`
- **Problem:** candidateJSONNames enumerates suffix variants, the (n) counter relocation, and ~46-char truncation, but treats them as independent cases. It does not generate the combined 'long name + (n) counter' candidate (truncated base + relocated counter), and prefix(46) counts Swift Characters (grapheme clusters) while Google truncates by UTF-8/UTF-16 bytes, so filenames containing multi-byte characters truncate at the wrong boundary and the candidate won't exist on disk. When no JSON matches, TakeoutSource silently falls back to EXIF/mtime for the date (bestTakenAt) and skips folding description/GPS/favorite — the photo still imports, just without its Google-side metadata. So this is metadata-loss on edge-case filenames, not a crash or media loss.
- **Suggested fix:** Add a combined truncation+counter candidate, and when name.count differs from its UTF-8 length, also emit a byte-based prefix. Optionally, as a last resort, scan the directory for a JSON whose base matches after stripping known suffixes. Confirm against a real Takeout export with long unicode filenames before changing, since Google's exact rule varies by export vintage.
- **Effort:** M

### L42 — Duplicated EXIF-date, thumbnail-options, and read-only-delete logic across sources

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/VolumeSource.swift:97-106`, `Sources/OpenPhotoCore/Import/TakeoutSource.swift:117-125`, `Sources/OpenPhotoCore/Import/VolumeSource.swift:189-196`, `Sources/OpenPhotoCore/Import/TakeoutSource.swift:95-102`, `Sources/OpenPhotoCore/Import/ForeignVaultSource.swift:92-98`, `Sources/OpenPhotoCore/Import/ForeignVaultSource.swift:72-74`, `Sources/OpenPhotoCore/Import/TakeoutSource.swift:89-91`, `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:99-101`
- **Problem:** Three near-identical implementations of `exifDate(of:)` (VolumeSource static, TakeoutSource private — byte-for-byte the same DateFormatter+CGImageSource code), the same `CGImageSourceCreateThumbnailAtIndex` option dictionary copy-pasted in VolumeSource/TakeoutSource/ForeignVaultSource, and four hand-written read-only `delete()` stubs that each fabricate a different error string ("someone else's drive — read-only", "Takeout import is read-only", "Apple Photos import is read-only"). Drift risk: a fix or format addition (e.g. a second EXIF date key, or a transform option) must be made in several places and is easy to miss.
- **Suggested fix:** Hoist `exifDate(of:)` and the thumbnail-from-URL helper into one shared utility (or a default protocol-extension method) and have the file-backed sources call it. Provide a single `readOnlyDelete(_:reason:)` default for read-only sources so the message and shape are defined once.
- **Effort:** S

### L43 — Takeout/Photos '(edited)' naming and JSON matching are fragile and untested for collisions

- **Severity:** Low
- **Confidence:** Needs verification
- **Category:** design
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:121-125`, `Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift:63-76`, `Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift:9-32`, `Sources/OpenPhotoCore/Import/TakeoutSource.swift:63-66`
- **Problem:** `editedName` produces "IMG_0001 (edited).heic" while the original is "IMG_0001.heic"; both go through the engine's collision-free placement so the relationship between an original and its edited sibling is purely name-convention with no test coverage for the case where a source already contains a file literally named "... (edited)". The Takeout matcher enumerates a hand-maintained list of suffix/truncation/`(n)` candidates and returns the first that exists on disk — a heuristic with several known Google quirks but no unit tests in this subsystem verifying the truncation-length (46) and the post-extension `(n)` hop against real Takeout fixtures, so a silently-wrong match (or miss) would carry the wrong capture date/GPS into a file with no signal to the user. This is maintainability/test-coverage risk around a correctness-sensitive heuristic.
- **Suggested fix:** Add fixture-based unit tests for `TakeoutJSONMatcher.candidateJSONNames` (truncation boundary, `(1)` before/after extension, supplemental-metadata variants) and for `editedName` collision behavior, so future export-format changes are caught. Consider deriving the truncation length from observed data rather than a magic 46.
- **Effort:** M

### L44 — Full filesystem paths embedded in sourceKey and raw error strings surfaced to UI/registry

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** security
- **Subsystem:** Import (foreign / PhotoKit / Takeout / camera)
- **Location:** `Sources/OpenPhotoCore/Import/TakeoutSource.swift:17`, `Sources/OpenPhotoCore/Import/VolumeSource.swift:27`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:107`, `Sources/OpenPhotoCore/Import/ImportEngine.swift:122`, `Sources/OpenPhotoApp/Devices/ImportView.swift:324`
- **Problem:** TakeoutSource/VolumeSource derive `sourceKey` from the absolute on-disk path when no volume UUID is available; this key is persisted durably into imports.jsonl (ImportRegistry.Entry.sourceKey) and is documented as part of the on-disk format, so a user's home-directory path can be baked into a sovereign data file and travels with the vault. Separately, `String(describing: error)` is funneled straight into `FailedItem.reason` and into `phase = .failedToConnect(...)`, which can embed absolute paths / low-level NSError detail directly in the user-facing UI. Neither is a hard security hole, but both leak local path structure into durable/visible surfaces.
- **Suggested fix:** For path-derived source keys, hash or relativize the path (or document that the path is intentionally part of the key) so a raw home path isn't persisted verbatim. Map fetch/connect errors to concise user-facing messages and keep the verbose `String(describing:)` form to a debug log rather than the registry/UI.
- **Effort:** S

### L45 — restore() treats an unknown-vault no-op as success and dequeues the pending deletion

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService.swift:327-336`
- **Problem:** `try binStores[entry.vaultID]?.restore(...)` uses optional chaining: if entry.vaultID has no BinStore (unknown/closed vault), the expression is a no-op that does NOT throw. Execution then proceeds to dequeuePendingDeletion and rescan as though the file were restored, so the UI reports a successful restore while nothing moved out of the bin and the pending-deletion record is cleared. This is an edge case (stale/unknown vaultID in a BinEntry) rather than the common path, but it fails silently.
- **Suggested fix:** Guard `binStores[entry.vaultID]` explicitly and throw (or surface) when the vault is unknown, rather than letting optional chaining swallow the missing-store case before the dequeue/rescan run.
- **Effort:** S

### L46 — Move-failure surface stringifies raw Swift errors into a user-facing dictionary

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/LibraryService+Move.swift:31`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:203`
- **Problem:** movePhotos records failures as `String(describing: error)`, which yields opaque enum/CocoaError text (e.g. `ReorgError.destinationExists`) that is then shown verbatim in an NSAlert. This is an inconsistent, leaky error representation compared with the folder-move path which surfaces `NSAlert(error:)` with a localized description, and it pushes raw internal type names into the UI.
- **Suggested fix:** Map ReorgError/CocoaError cases to short human-readable reason strings in movePhotos (or return the typed error and let the App layer localize), instead of `String(describing:)`.
- **Effort:** S

### L47 — XMP-serialize-and-atomic-write logic is duplicated across three sites

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** LibraryService, Sidecar, Interop, Selection
- **Location:** `Sources/OpenPhotoCore/Sidecar/SidecarStore.swift:16`, `Sources/OpenPhotoCore/Interop/SidecarExporter.swift:16`, `Sources/OpenPhotoCore/LibraryService.swift:232`
- **Problem:** `AtomicFile.write(Data(XMP.serialize(data).utf8), to: …)` is hand-written in SidecarStore.write and again in SidecarExporter.export, and LibraryService.updateMetadata separately encodes tags to JSON and writes the sidecar. The exact serialize+encode+atomic-write triple is the kind of format-touching code the project's documentation discipline wants funnelled through one path so the on-disk XMP shape can't drift between the live store and the export mirror. SidecarExporter also re-reads the manifest and re-implements the empty-skip loop that ingestSidecars already performs.
- **Suggested fix:** Route all sidecar writes through a single SidecarStore method (e.g. SidecarStore.write already exists — have SidecarExporter call a shared `serializeAndWrite(data:to:)` helper or reuse SidecarStore against the dest tree) so there is one serialization site and the export can't diverge from the canonical writer.
- **Effort:** S

### L48 — Live-photo and grouped-step assume openedItem still exists in the list; defensive only

- **Severity:** Low
- **Confidence:** Needs verification
- **Category:** correctness
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:14-17`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:200-206`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:47-55`
- **Problem:** flatItems falls back to state.flatItems when viewerItems is empty. If the underlying list is refreshed (refreshQueries after a delete/evict) while the viewer is open, openedItem may no longer be present in flatItems, making `index` nil; step() then returns early so arrow navigation silently dead-ends until the user closes/reopens. removeOpenedItem advances using the pre-removal list which mitigates the common delete path, but external refreshes (e.g. a folder watcher rescan, or evict completing) are not coordinated with the viewer's navigation set. No crash (all subscripting is index-guarded), but navigation can become a no-op with no feedback.
- **Suggested fix:** When the navigation set changes under an open viewer, re-resolve openedItem to the nearest surviving item (or close the viewer) rather than leaving index nil. Consider snapshotting viewerItems independently of live query refreshes so the open session has a stable ordered set.
- **Effort:** M

### L49 — step() / index recompute a full-array linear scan in body and on every navigation

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Media UI (tiles, viewer, timeline, peek)
- **Location:** `Sources/OpenPhotoApp/Viewer/ViewerView.swift:17`, `Sources/OpenPhotoApp/Viewer/ViewerView.swift:200-206`, `Sources/OpenPhotoApp/AppState.swift:1651`
- **Problem:** `index` is a computed property doing flatItems.firstIndex on every body evaluation, and step() repeats firstIndex on each arrow press. For a 50-100k-item library this is an O(n) scan per render/keystep. removeOpenedItem (AppState.swift:1651) does the same firstIndex scan. Not a correctness bug, but on a large flatItems it makes arrow-key navigation and delete-while-viewing do avoidable linear work. Boundary handling itself is correct (indices.contains guards prevent out-of-range).
- **Suggested fix:** Maintain the current index alongside openedItem (set it when openViewer/step assign the item) so navigation is O(1), or build an instanceID->index dictionary once when viewerItems/flatItems is set. Low priority unless profiling shows it matters.
- **Effort:** S

### L50 — DatePreset force-unwraps Calendar.date results — crash on calendar/year-math edge cases

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Search/DatePreset.swift:11`, `Sources/OpenPhotoCore/Search/DatePreset.swift:20-21`
- **Problem:** `daysAgo` force-unwraps `calendar.date(byAdding:.day,...)!` and the `.year` case force-unwraps `calendar.date(from: DateComponents(year: y, ...))!` for both `y` and `y+1`. `Calendar.date(from:)` returns nil for date components a calendar cannot represent (non-Gregorian calendars where the requested Jan-1 is undefined, or extreme/overflowing year values such as a `.year(Int)` deep-link or a corrupt stored filter). Because this runs at filter-build time, a nil here crashes the app rather than failing the search gracefully. It is the standard `.current` Gregorian calendar in normal use, hence Suspected rather than Confirmed, but the inputs (`year(Int)` is public and unbounded) are attacker/data-reachable.
- **Suggested fix:** Guard the optionals and fall back to a safe range (e.g. return `now...now` or an empty/clamped range) on nil, or clamp `y` to a sane span. At minimum avoid `!` so a pathological year can't crash filter construction.
- **Effort:** S

### L51 — IN(...) / OR fan-out has no chunking against SQLite host-variable limit on large libraries

- **Severity:** Low
- **Confidence:** Needs verification
- **Category:** correctness
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Search/Catalog+Search.swift:164-181`, `Sources/OpenPhotoCore/Catalog/Queries.swift:88-96`, `Sources/OpenPhotoApp/AppState.swift:490-517`
- **Problem:** `items(forHashes:)` builds `hash IN (\(marks))` with one bound parameter per hash, and runSearch calls it with `ranked`/`structured` that, when filters are empty, equal `allHashesNewestFirst()` — i.e. EVERY hash in the library. Similarly `items(instanceIDs:)` binds one param per id. SQLite enforces `SQLITE_MAX_VARIABLE_NUMBER` host parameters per statement (999 on old builds, 32766 on modern). The GRDB-bundled SQLite is almost certainly the higher cap, so a 10k-photo library (the stated acceptance target) is fine; but a 33k+ library would throw 'too many SQL variables', which the surrounding `try?` then silently turns into empty search results (see the error-swallowing finding). Needs verification of the exact bundled SQLite cap; flagging because there is no chunking and the failure is invisible.
- **Suggested fix:** Chunk the IN-list (e.g. batches of 900) and union the fetched rows, or rewrite the large 'all hashes' path to fetch directly from the timeline union with ORDER BY rather than round-tripping hashes back through an IN-list. Confirm the bundled SQLITE_MAX_VARIABLE_NUMBER first.
- **Effort:** M

### L52 — Drive-only dedup-by-MIN(rowid) SQL is duplicated between the timeline union and folderCounts

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Catalog/Queries.swift:18`, `Sources/OpenPhotoCore/Catalog/Queries.swift:24`, `Sources/OpenPhotoCore/Catalog/Queries.swift:25`, `Sources/OpenPhotoCore/Catalog/Queries.swift:122`, `Sources/OpenPhotoCore/Catalog/Queries.swift:126`, `Sources/OpenPhotoCore/Catalog/Queries.swift:127`
- **Problem:** The drive-only branch logic — `NOT EXISTS (SELECT 1 FROM instances ...)` combined with `vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.hash = ...)` to pick one drive row per asset — is hand-written twice: once in driveSelect (used by the timeline union) and again, separately, inside folderCounts' drive branch. The two must stay in lockstep (same dedup semantics, same isLivePairedVideo=0 filter) or folder counts will silently diverge from what the grid shows. Any future change to dedup policy (e.g. preferring canonical drive over MIN(rowid)) has to be remembered in both places.
- **Suggested fix:** Factor the drive-only predicate into a single shared SQL fragment (a private static String like the existing localSelect/driveSelect) and reuse it in folderCounts so the dedup rule lives in exactly one location. Consider also covering it with a unit test asserting timeline-union counts equal folderCounts sums.
- **Effort:** S

### L53 — SemanticIndex.query sorts all scores instead of partial top-N selection

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Queries & Search
- **Location:** `Sources/OpenPhotoCore/Search/SemanticIndex.swift:36`, `Sources/OpenPhotoCore/Search/SemanticIndex.swift:37`
- **Problem:** query() runs `scores.enumerated().sorted { $0.element > $1.element }.prefix(n)` — a full O(count log count) sort plus an allocation of an [(offset, element)] array of size count — every search, only to keep topN=300. For a 10k-embedding library this is a small but avoidable per-keystroke cost on top of the vDSP_mmul; for larger libraries it grows. Correctness is fine (ties and NaN aside).
- **Suggested fix:** Use a bounded selection: maintain a size-N min-heap, or use a partial-sort / nth_element-style partition over the scores buffer, to get top-N in O(count log N) without sorting the entire array or allocating the full enumerated pairs.
- **Effort:** S

### L54 — extractImage GPS/Exif reads assume exact dynamic types; live-pair contentIdentifier key is fragile

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Media/MetadataExtractor.swift:44-55`
- **Problem:** GPS latitude/longitude are read as `as? Double`; ImageIO usually bridges these as NSNumber (which casts to Double fine), but rational/string-encoded GPS in some files would yield nil and silently drop location. The Apple Live Photo content identifier is read as `apple['17' as CFString]` — a magic maker-note key that can change across formats; if it is absent or under a different representation, content-identifier pairing silently falls back to the basename heuristic. These are graceful-degradation paths, not crashes, but they cause silent metadata loss on edge-case files.
- **Suggested fix:** Accept NSNumber explicitly and convert (`(gps[...] as? NSNumber)?.doubleValue`). Document the '17' maker-note assumption and treat a missing value as 'unknown' (already the behavior) — keep the basename fallback as the safety net (it exists in LivePhotoPairer).
- **Effort:** S

### L55 — BackupProbe is dead production code duplicating PresenceService's API

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Presence/BackupProbe.swift:6-24`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:29-31`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:99-112`
- **Problem:** BackupProbe has no production callers anywhere in Sources/ (grep finds only its own definition and a doc-comment mention in PresenceService that says it 'Supersedes Stage A's BackupProbe'). It exposes isOnlyOnThisMac(hash:) and onlyOnThisMac(hashes:) with the same names and semantics as PresenceService, so the two now present two parallel only-copy abstractions where one is authoritative and one is orphaned. Keeping a superseded, untethered probe invites a future caller to wire up the weaker (import-registry-only) judgment by mistake, which would under-report only-copies and weaken the eviction safety check.
- **Suggested fix:** Delete BackupProbe.swift (and its now-redundant BackupProbeTests) since PresenceService.isOnlyOnThisMac fully covers the need; or, if a lightweight import-only probe is still wanted, fold it into PresenceService as a documented mode so there is a single only-copy authority.
- **Effort:** S

### L56 — Force-unwrapped fm.enumerator()! can crash the scan

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Scanner/Scanner.swift:27-28`
- **Problem:** `fm.enumerator(at: vault.rootURL, ...)!` force-unwraps. FileManager returns nil when the root URL is not a reachable/enumerable directory (e.g. the vault root was unmounted or deleted between open and scan, or permissions changed). In that case the whole scan task traps instead of surfacing a recoverable error, which is harsher than the rest of this function which deliberately degrades (skips unreadable files, tolerates nil sizes). It is a latent crash in an otherwise defensively-written routine.
- **Suggested fix:** `guard let enumerator = fm.enumerator(...) else { throw <a scan error / return an empty Result> }` so a vanished root produces a handled error rather than a trap.
- **Effort:** S

### L57 — Live Photo pairing depends on non-deterministic filesystem enumeration order

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** design
- **Subsystem:** Scanner, Presence, Media
- **Location:** `Sources/OpenPhotoCore/Media/LivePhotoPairer.swift:31-32`, `Sources/OpenPhotoCore/Media/LivePhotoPairer.swift:52-55`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:119-121`
- **Problem:** videosByCid and videosByKey are built with last-write-wins (`videosByCid[c] = v`, `videosByKey[key] = v`). When two videos legitimately or accidentally share a content identifier or a dir+basename key, which one wins depends on iteration order of `candidates`, which comes from `aligned` → `found` → FileManager.enumerator order, which is not a guaranteed stable ordering. The same is true for which photo claims a video. The result is that across two scans of the same library the chosen video in a Live Photo pair can differ, producing non-reproducible catalog state (different livePairHash) for the same on-disk content. This is a structure/maintainability hazard more than a user-facing bug, but it makes pairing results harder to reason about and test.
- **Suggested fix:** Sort candidates deterministically (e.g. by relPath) before building the lookup dictionaries, or detect/handle collisions explicitly (first-by-path wins, or skip ambiguous groups) so pairing is reproducible regardless of enumeration order.
- **Effort:** S

### L58 — Filter-bar facet load uses an id-less .task that never refreshes after library changes

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** SwiftUI
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Search/ProFilterBar.swift:38-43`, `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift:40-44`
- **Problem:** Both filter bars populate cameras/tags/people/places from the catalog in a `.task { }` with no `id:`. The task runs once when the view first appears and never re-runs while the view stays mounted. After an import, a tag edit, or a geocode pass adds new cameras/tags/people/places, the menus stay stale until the search view is torn down and recreated. The facet lists are also re-fetched independently in each bar even though they overlap, and there is no invalidation tie to library mutations.
- **Suggested fix:** Key the task to a value that changes when facets could change (e.g. `.task(id: state.refreshToken)` or a dedicated facet-version token bumped on import/metadata writes), or load facets centrally in AppState and observe them so both bars share one source of truth.
- **Effort:** S

### L59 — Duplicate-hash photo switch does not reload Inspector editable state

- **Severity:** Low
- **Confidence:** Needs verification
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Inspector/InspectorView.swift:230`, `Sources/OpenPhotoApp/Inspector/InspectorView.swift:398`
- **Problem:** The Inspector reloads its editable @State via `.task(id: item.hash)`. CleanupView's own header comment establishes that a single content hash legitimately recurs across distinct file instances (duplicates in different folders). Navigating the viewer between two such instances does not change item.hash, so the .task does not re-fire and load() is not re-run. Because human metadata is hash-keyed, the editable fields (caption/rating/tags) are in fact identical for both instances, so there is no data loss; but if the user had unsaved edits on the first instance they silently carry over, and any per-instance display reset tied to load() is skipped. Low impact but the id should arguably be item.instanceID for symmetry with the rest of the UI.
- **Suggested fix:** Key the reload on item.instanceID (or item.hash + relPath) so switching between same-hash instances re-runs load(); combine with the pending-edit flush from the lost-edit finding.
- **Effort:** S

### L60 — state.library! force-unwrapped in Search and Cleanup tile construction

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Search/SearchView.swift:119`, `Sources/OpenPhotoApp/Cleanup/CleanupView.swift:148`
- **Problem:** Both views build ThumbnailImage with library: state.library!. These views are only reachable while RootView has already checked state.library != nil, so in the normal flow the unwrap is safe. But the unwrap is unguarded: if the library is closed (state.library set to nil at AppState.swift:1382) while a search/cleanup view body is still being evaluated during the SwiftUI transition back to WelcomeView, this force-unwrap traps and crashes the app. ProFilterBar/SimpleFilterBar correctly use state.library?.catalog with try?, so this is an inconsistency as well as a latent crash.
- **Suggested fix:** Guard against a nil library at the top of resultGrid/content (e.g. `guard let library = state.library else { return EmptyView() }`) and pass the non-optional binding into the tiles, instead of force-unwrapping per cell.
- **Effort:** S

### L61 — Duplicated filter-bar helpers and chip styling across Simple/Pro bars

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Search/ProFilterBar.swift:358-379`, `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift:247-271`, `Sources/OpenPhotoApp/Search/SimpleFilterBar.swift:137-162`, `Sources/OpenPhotoApp/Search/ProFilterBar.swift:119-137`
- **Problem:** folderPaths(), folderLabel(), and the pill/chip styling (menuChip / filterChip — same padding, radius 7, accentDim/elevated background and stroke) are duplicated verbatim between ProFilterBar and SimpleFilterBar, and the Date menu (Any date / relative presets / recentYears) is implemented twice with the same structure. This is low-risk now but means visual and behavioural drift between the two modes as the filter UI evolves (e.g. a fix to folder flattening or chip styling must be made in two places).
- **Suggested fix:** Extract the shared folder helpers and chip-style view builder into a small shared file/extension (or reuse the existing FilterChip styling), and factor the Date menu into one reusable view parameterised by its setter.
- **Effort:** S

### L62 — recentYears couples to the relative-preset list via a hardcoded -2 offset

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Search UI, Inspector, Cleanup, Selection UI
- **Location:** `Sources/OpenPhotoApp/Search/DatePreset+UI.swift:23-26`, `Sources/OpenPhotoApp/Search/DatePreset+UI.swift:19`
- **Problem:** recentYears(asOf:count:) starts at `current - 2` specifically because `.thisYear` and `.lastYear` already appear in `relative`. This couples two separate lists by a magic constant with only a comment to enforce it: if `.lastYear` is ever removed from `relative` (or another recent-year preset is added), the year menu silently gains or loses a duplicate/gap year with no compile-time link. There is no test asserting the no-overlap invariant.
- **Suggested fix:** Derive the offset from the relative presets (e.g. compute how many trailing recent years `relative` already covers) or add a small unit test asserting that recentYears(asOf:) shares no year with the years implied by .thisYear/.lastYear, so the invariant is checked rather than commented.
- **Effort:** S

### L63 — connectedSendTargets recomputed in body with per-volume IO

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** SwiftUI
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoApp/Timeline/TimelineView.swift:66`, `Sources/OpenPhotoApp/Timeline/TimelineView.swift:141`, `Sources/OpenPhotoApp/Folders/FolderGridView.swift:69`, `Sources/OpenPhotoApp/AppState.swift:1699`
- **Problem:** connectedSendTargets and connectedSendTarget filter deviceWatcher devices by calling sendDestination for each device, which for each volume builds a fresh VolumeCopyDestination including resolvingSymlinksInPath and a volumeUUIDString resourceValues lookup, a stat or IO call, purely to answer a boolean is-valid-target test. These are called inside TimelineView body and inline closures (66, 141) and FolderGridView (69), so each re-render does filesystem IO per connected volume on the main actor.
- **Suggested fix:** Add a cheap canReceiveSend predicate on ConnectedDevice that constructs no destination and filter on that; build the real SendDestination only when a send starts, or cache the targets list on AppState and recompute only on device-watcher change.
- **Effort:** S

### L64 — Present-match logic duplicated across engine and reverifier

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/SendEngine.swift:80`, `Sources/OpenPhotoCore/Send/SendReverifier.swift:23`
- **Problem:** The rule preferring an authoritative content hash when present, else looselyMatches on size and capture-second, is implemented verbatim in SendEngine.isPresent (80-85) and SendReverifier.reconcile (28-31); the reconcile doc comment even states it is identical to SendEngine.isPresent. The two can silently drift if the rule changes, splitting dedup behaviour from reverify verdicts for the same asset.
- **Suggested fix:** Extract one shared predicate on PresenceFingerprint (which SendDestination.swift already owns) and call it from both SendEngine.isPresent and SendReverifier.reconcile.
- **Effort:** S

### L65 — DeviceRegistry silently drops a record on per-entry encode failure

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/DeviceRegistry.swift:66`, `Sources/OpenPhotoCore/Send/DeviceRegistry.swift:69`
- **Problem:** upsert rewrites the whole devices.jsonl with `if let d = try? enc.encode(e) { out.append(d) … }` per entry and then `try? AtomicFile.write(out, to: url)`. If any single entry fails to encode it is silently omitted from the rewritten file — a previously-known device record is lost on the next upsert — and a failed atomic write is swallowed entirely (the in-memory byKey says success but disk is stale). SendRegistry.append (the parallel file) deliberately uses throwing `try enc.encode` and `try AtomicFile.write` (SendRegistry.swift:89,91) so failures propagate; DeviceRegistry is the inconsistent, lossier one. Impact is bounded (friendly-name cache, not the authoritative send log) but it is a silent data-loss-of-record path.
- **Suggested fix:** Mirror SendRegistry: encode with throwing `try` and propagate the AtomicFile.write error (make upsert `throws` or at least log/surface the failure) so a record is never silently dropped and a failed persist is observable.
- **Effort:** S

### L66 — enumeratePresent re-hashes every file on the volume with no per-file autoreleasepool or cancellation

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** memory
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:21`, `Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift:27`
- **Problem:** enumeratePresent walks the whole destination subfolder and computes a full streaming SHA-256 of every media file on every send and every reverify. The per-file loop (resourceValues, FileHandle reads inside ContentHash) yields autoreleased objects but has no enclosing autoreleasepool around the body, unlike the documented care taken in ContentHash.ofFile (and the indexing OOM lesson in project memory about missing pools per-file). For a volume that already holds thousands of items this both wastes a lot of I/O and lets transient per-file autoreleased buffers accumulate across the loop. There is also no Task.checkCancellation()/Task.isCancelled, so a user who dismisses the sheet cannot stop a long enumeration; it runs to completion off-actor. Note the send() copy loop likewise has no cancellation check, so 'cancellation cleanup' is effectively absent on the send path.
- **Suggested fix:** Wrap each iteration of the enumeratePresent loop (and ideally the send() copy loop) in autoreleasepool, and add `try Task.checkCancellation()` per iteration so dismissing the sheet stops the work. For the recurring enumeration cost, consider caching fingerprints keyed by (size, mtime) so unchanged files aren't re-hashed each time.
- **Effort:** M

### L67 — Registry queries are full linear scans in hot loops

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** Send (device/volume copy-out)
- **Location:** `Sources/OpenPhotoCore/Send/SendRegistry.swift:57`, `Sources/OpenPhotoCore/Send/SendRegistry.swift:63`, `Sources/OpenPhotoCore/Send/SendRegistry.swift:71`, `Sources/OpenPhotoApp/Devices/ImportView.swift:386`, `Sources/OpenPhotoCore/Presence/PresenceService.swift:69`
- **Problem:** entries forDestinationKey, entries forHash, and wasSentToDevice all scan the full byKey values dictionary. ImportView.rebuildSentCache calls wasSentToDevice once per displayed device item (384-388), so the sent-badge computation grows as items multiplied by total send history; PresenceService calls entries forHash per asset (69). Cost grows with lifetime send history across the whole import and presence view.
- **Suggested fix:** Maintain secondary indexes alongside byKey, one keyed by destinationKey and one by hash, rebuilt on load and maintained on append, so the per-item and per-device queries become constant or proportional to matches instead of to history.
- **Effort:** M

### L68 — Sparkle updater held as plain `let` instead of `@State` on the App

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** SwiftUI
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/OpenPhotoApp.swift:9-10`
- **Problem:** `SPUStandardUpdaterController(startingUpdater: true, ...)` is stored as a non-owned `let` property on the `App` value type. App structs are values SwiftUI may re-create/copy; a `let` initializer expression is re-evaluated whenever the struct is reinitialized, which for an object that starts a background updater on init is the kind of thing that should be guaranteed single-instance. In practice `@main` App is instantiated once so this works today, but the idiomatic and safe form is `@State private var updaterController = ...` so SwiftUI owns exactly one instance for the App's lifetime regardless of struct re-evaluation.
- **Suggested fix:** Change to `@State private var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` to pin a single owned instance.
- **Effort:** S

### L69 — Settings library-size aggregate query runs synchronously on the main actor

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** concurrency
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Settings/SettingsView.swift:67`, `Sources/OpenPhotoApp/Settings/SettingsView.swift:68`
- **Problem:** The `.task(id: state.refreshToken)` body runs on the MainActor (it's a SwiftUI View task) and calls `state.library.flatMap { try? $0.catalog.librarySize() }`, which performs a synchronous GRDB read (COUNT(*) + SUM(size) over the instances table, Queries.swift:205) on the main thread. The cost is small for an indexed aggregate, but it is unbounded by library size, re-fires on every refreshToken bump, and blocks the main actor for its duration. The pattern also swallows any DB error via try?, so a failed read just shows no stats with no signal.
- **Suggested fix:** Move the read off-main, e.g. `libStats = await Task.detached { try? lib.catalog.librarySize() }.value`, capturing the library locally first; consider distinguishing a read failure from a genuinely empty library if that matters to the UI.
- **Effort:** S

### L70 — Fragile state.library! force-unwraps in Bin and Send views

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Bin/BinView.swift:32`, `Sources/OpenPhotoApp/Send/SendSheet.swift:80`
- **Problem:** BinThumb(... library: state.library!) and ThumbnailImage(... library: state.library!) force-unwrap the optional library. Today these are reached only when state.library != nil (BinView is rendered inside RootView's non-nil-library branch; SendSheet's warningView only renders after a plan is built). However, library is set to nil asynchronously by closeLibrary()/changeRoot()/closeLibraryAndForgetRoot(); a SendSheet sheet (or a mid-render Bin grid) that is still alive when the library is torn down (e.g. Change Library from the Settings window while the sheet is up) would trap. The invariant that protects these unwraps is non-local and not enforced at the call site.
- **Suggested fix:** Pass the unwrapped library down explicitly (the parent already holds it) or guard with `if let library = state.library` and render a neutral placeholder otherwise, so a teardown race degrades gracefully instead of crashing.
- **Effort:** S

### L71 — Empty-bin can leave a stale bin log if the log rewrite fails after a successful trash

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** file-integrity
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Bin/BinView.swift:60`, `Sources/OpenPhotoApp/Bin/BinView.swift:62`, `Sources/OpenPhotoApp/Bin/BinView.swift:63`, `Sources/OpenPhotoApp/Bin/BinView.swift:65`
- **Problem:** confirmEmpty() trashes the whole bin/ directory (BinView.swift:63) and only then writes an empty bin.jsonl (line 65). If trashItem succeeds but AtomicFile.write(Data()) throws (e.g. transient FS error), the catch shows the error but the bin directory is already gone while bin.jsonl still lists entries. binItems() then returns BinEntries whose backing files no longer exist; their thumbnails fail to load and clicking Restore silently fails (see related finding). The on-disk bin state is left internally inconsistent.
- **Suggested fix:** Make empty-bin a single store-level operation in BinStore/LibraryService that writes the empty log first (or treats a missing bin/ dir as an empty bin during list()), and reconcile list() to tolerate a missing directory. At minimum, on the write failure path re-derive/repair the log from the now-empty directory rather than leaving stale entries.
- **Effort:** M

### L72 — Send warning view recomputes grouping + per-group filtering on every render

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/Send/SendSheet.swift:63-65`, `Sources/OpenPhotoApp/Send/SendSheet.swift:105-108`
- **Problem:** `warningView(_:)` is a plain function called from `body`, so every time the sheet re-renders while the warning is shown it rebuilds `Dictionary(grouping: plan.unreachable, by: \.driveName)`, sorts it, and for each drive group calls `thumbItems(for:)` which does `items.filter { wanted.contains($0.hash) }` — an O(unreachable + groups × selection) pass each render. For a large multi-drive selection this repeats on unrelated state changes (e.g. progress ticks, hover). It's bounded to the unreachable-warning screen so impact is limited, but it is avoidable repeated work over a potentially large `items` array.
- **Suggested fix:** Compute the grouped/thumbnail structure once when `plan` is set (e.g. derive it in `prepareThenMaybeSend` into an `@State` value, or memoize keyed on `plan`), and have `warningView` read the precomputed structure instead of regrouping/refiltering per render.
- **Effort:** S

### L73 — scheduleReposition() self-reschedules forever with no cap if the view never attaches to a window

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** performance
- **Subsystem:** App shell (entry, window, sidebar, settings, send UI, bin)
- **Location:** `Sources/OpenPhotoApp/WindowControls.swift:62`, `Sources/OpenPhotoApp/WindowControls.swift:63`, `Sources/OpenPhotoApp/WindowControls.swift:109`, `Sources/OpenPhotoApp/WindowControls.swift:110`
- **Problem:** reposition() bails with `guard let window = view?.window else { scheduleReposition(); return }`, and scheduleReposition() re-dispatches to the main queue immediately with no delay, backoff, or attempt limit. In normal use the backing NSView attaches within a frame or two and the loop terminates. But if the representable's NSView is ever instantiated without ever being placed in a window (or the window is torn down while a reposition is queued), this becomes an unbounded main-queue busy-loop that re-runs every runloop iteration, burning CPU. The same applies to TitleBarDoubleClickZoom.schedule()/install() at WindowControls.swift:164,166.
- **Suggested fix:** Add a bounded retry (e.g. cap attempts or stop after N tries / a short deadline) and/or a small delay between reschedules, so a permanently window-less view stops re-arming instead of spinning the main queue.
- **Effort:** S

### L74 — DrivePathMap.driveToMacRelPath silently mismaps when a Mac source root basename collides with a sub-folder name

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/CatalogIngest.swift:46`, `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:143`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:8`
- **Problem:** driveToMacRelPath strips the first path component if it equals ANY configured source-vault basename. Drive paths are produced as '<sourceRootBasename>/<relPath>' (SyncEngine.driveRelPath), so this is correct for top-level mirrors, but if a user has a source root literally named e.g. 'Photos' and ALSO an unrelated drive folder 'Photos/...' that did not originate from that root (or two source roots share a basename), the mapping is ambiguous and will rewrite the Mac-aligned relPath/dirPath incorrectly. This only affects derived presence/folder display (driveRelPath remains authoritative for the actual file), so it's not data loss, but folder grouping and the deletion 'relPath for display' can point at the wrong logical location. Couldn't confirm a basename collision is reachable from the UI's root-add flow.
- **Suggested fix:** Disambiguate by requiring the stripped prefix to match the source root the entry actually came from (carry the originating vaultID/basename per manifest entry, or reject duplicate source-root basenames at add time). At minimum document the duplicate-basename hazard.
- **Effort:** M

### L75 — Free-space guard ignores sidecar bytes (and snapshot/manifest overhead)

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/SyncEngine.swift:128`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:45`, `Sources/OpenPhotoCore/Sync/SyncPlan.swift:17`
- **Problem:** The ENOSPC guard compares free space only against plan.totalCopyBytes, which is accumulated solely from `copies` (SyncEngine:45). plan.sidecarUpdates bytes and the rewritten manifest are not counted. On a nearly-full drive a sync can pass the guard, copy all media, then ENOSPC while writing sidecars or the manifest — sidecars are written with AtomicFile (temp+rename) so a failure is clean, but it produces partial-result confusion (media copied, sidecars/manifest failed) rather than the clean up-front refusal the guard intends. Low impact because writes are atomic and failures are recorded, but the guard is weaker than it claims.
- **Suggested fix:** Add sidecar byte totals (sum of sidecarUpdates sizes) to the free-space check, plus a small fixed slack for the manifest rewrite, before starting the copy loop.
- **Effort:** S

### L76 — PeekSource.import / verifyAdoption call replaceVaultPresence, clobbering live verified presence with snapshot-derived data

- **Severity:** Low
- **Confidence:** Suspected
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:89`, `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:154`, `Sources/OpenPhotoCore/Catalog/Catalog.swift:264`
- **Problem:** import() does replaceVaultPresence(vaultID: drive, entries: <snapshot presence>) — a full DELETE+reinsert of that drive's presence rows. If the live catalog already held DRIFT-VERIFIED presence for this drive (e.g. from a prior driftScan that re-hashed reality), re-running import (adopt, or a Quick View into a temp catalog is harmless, but adoptDrive uses the REAL catalog at AppState:1020) replaces verified reality with the snapshot's potentially-stale claim. verifyAdoption immediately afterward reconciles against the manifest (good) but only trusts manifest hashes as 'present' WITHOUT confirming the files exist on disk, so a drive whose snapshot/manifest list files that were since removed will show them as present until the next full driftScan. This trusts non-authoritative snapshot+manifest over previously-verified presence between the import and the next scan.
- **Suggested fix:** When importing into the real catalog (adopt path), prefer the existing verified presence where present, or always immediately follow import+verifyAdoption with a fast driftScan before exposing the drive as browsable, so on-disk reality (not the snapshot) is authoritative for presence.
- **Effort:** M

### L77 — Snapshot/peek read paths swallow all errors, masking unreadable or corrupt snapshots

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:112`, `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:117`, `Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift:118`, `Sources/OpenPhotoApp/AppState.swift:644`, `Sources/OpenPhotoApp/AppState.swift:1020`, `Sources/OpenPhotoApp/AppState.swift:1021`
- **Problem:** assetDates() returns nil on any error (`try?` on both the DatabaseQueue open and the read), and adoptDrive/import/verifyAdoption are all invoked via `try?` at the call sites — so a corrupt, locked, or schema-mismatched snapshot DB is indistinguishable from 'no snapshot'. The consequences are mostly graceful fallbacks (assetDates -> manifest mtimes; PeekSource.import is inside a `try?` so it falls back to raw), but adoptDrive(AppState:1020-1021) discards failures of BOTH import and verifyAdoption with no user feedback: a user adopts a drive, sees no error, and silently gets an incomplete/stale presence set. The snapshot is non-authoritative so this isn't data loss, but the silent failure makes 'adopt did nothing' undiagnosable.
- **Suggested fix:** In assetDates, keep the nil fallback but log the open/read error. In adoptDrive, propagate the import/verifyAdoption error into a user-facing alert (the manifest-reconcile in verifyAdoption is the safety net, but if IT throws the user should know the adopt was partial).
- **Effort:** S

### L78 — Duplicated diff and sidecar-path logic across plan/planClone and propagate/deleteDriveOnly

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/SyncEngine.swift:28`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:48`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:86`, `Sources/OpenPhotoCore/Sync/SyncEngine.swift:103`, `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift:48`, `Sources/OpenPhotoCore/Sync/DeletionPropagator.swift:97`
- **Problem:** plan() and planClone() carry near-identical copy/conflict-decision blocks (known-hash-equal→skip, known-hash-differ→conflict, dest-exists→hash-and-compare, else→copy) and the same '<dir>/.openphoto/<file>.xmp' sidecar-rel construction, differing only in the path mapping (driveRelPath vs identity). propagate() and deleteDriveOnly() are also structural twins: same loop binning files, accumulating clearedHashes/clearedDrivePaths, then one manifest rewrite + presence removal + sync-log — differing only in BinOrigin (.propagated vs .user) and the queue-clear step. The sidecar-rel string is built in three places (SyncEngine.plan, SyncEngine.planClone, AppState presence paths). Drift between these copies risks subtle one-way/diff inconsistencies over time.
- **Suggested fix:** Extract the copy/conflict decision into one helper taking a path-mapping closure, factor the sidecar-rel-path computation into a single shared function, and unify propagate/deleteDriveOnly around one private routine parameterized by BinOrigin + an optional queue-clear callback.
- **Effort:** M

### L79 — SyncLog.append rewrites the whole log file on every append

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** performance
- **Subsystem:** Sync (one-way, drift, deletion propagation)
- **Location:** `Sources/OpenPhotoCore/Sync/SyncLog.swift:5`, `Sources/OpenPhotoCore/Sync/SyncLog.swift:12`, `Sources/OpenPhotoCore/Sync/SyncLog.swift:14`
- **Problem:** append() reads the entire existing sync-log into memory, appends one line, and AtomicFile.write()s the whole thing back (temp+fsync+rename). That is O(file size) per append and O(n^2) over the log's lifetime. In practice the log gets one line per high-level operation (sync/delete/import/evict/rehydrate/send), not per file, so realistic growth is modest (hundreds of lines), which keeps this Low — but the type is documented as 'append-only' yet implemented as a full rewrite, so the cost is invisible to callers and will degrade if anyone ever logs per-file.
- **Suggested fix:** Open the file with FileHandle for appending (or use Data write with .append semantics) and write only the new line + newline, creating the file if absent. Atomicity of a single-line append to a JSONL log is not required for correctness here.
- **Effort:** S

### L80 — restore() drops ALL bin-log entries sharing a relPath and has no collision handling at the restore target

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** correctness
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/BinStore.swift:42-56`, `Sources/OpenPhotoCore/Vault/BinStore.swift:55`
- **Problem:** restore() does `writeLog(try list().filter { $0.path != relPath })`, which removes every log entry whose path matches — but the bin log keys items by hash+path+deletedAt, not uniquely by path, so two distinct files binned at the same vault-relative path (e.g. a name reused after a previous delete) would both be purged from the log when one is restored, leaving the other physically in bin/ but invisible/unrecoverable through the UI. Separately, restore (line 47) does a bare moveItem(at:to:) with no collision check: if a new file now occupies the original relPath (re-imported under the same name after deletion), the restore throws instead of placing the file collision-free — unlike moveFile, which uses FileNaming.collisionFreeURL. Edge cases, but they sit on the recovery path where surprises are costly.
- **Suggested fix:** Filter the log by the full item identity (hash+path+deletedAt) rather than path alone, and route the restore placement through FileNaming.collisionFreeURL (or surface a clear 'destination occupied' result) so a restore can't fail or silently orphan a binned file.
- **Effort:** S

### L81 — Redundant non-lenient ISO8601 parser is a silent foot-gun (mtime falls back to now)

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** design
- **Subsystem:** Vault, IO, Hashing
- **Location:** `Sources/OpenPhotoCore/Vault/VaultDescriptor.swift:47-57`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:139`
- **Problem:** ISO8601Millis exposes both dateLenient(from:) (accepts with OR without fractional seconds) and date(from:) (fractional-only). The fractional-only date(from:) is functionally a subset of dateLenient and is the kind of duplicated/near-identical API that invites the wrong call. Scanner.swift:139 uses the strict date(from:) with `?? Date()`, so a manifest entry whose mtime lacks fractional seconds (entirely valid ISO-8601, and producible by any third-party writer per the format's third-party-implementor goal) silently parses as nil and the catalog records the current time as the photo's mtime instead of failing or using the real value. The non-strict variant exists precisely to avoid this.
- **Suggested fix:** Remove the strict ISO8601Millis.date(from:) (or mark it private) and have all read paths use dateLenient; update Scanner.swift:139 to dateLenient so manifest mtimes written without fractional seconds aren't silently replaced by Date().
- **Effort:** S

---

## Appendix A — Investigated but not confirmed

_These were raised by an auditor but an independent verifier could not confirm them against the code. Listed for transparency; treat as low-priority or already-handled._

- **deleteEmptyFolder hard-deletes .openphoto/ sidecars (data loss, violates never-hard-delete)** (Vault, IO, Hashing, auditor said Critical/file-integrity) — `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:36`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:40`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:43`, `Sources/OpenPhotoCore/Vault/VaultReorganizer.swift:44`, `Sources/OpenPhotoApp/AppState+FolderReorg.swift:266`
  - Auditor's concern: The 'empty folder' guard at line 40 only counts entries that are not dotfiles and not '.openphoto'. A folder whose only remaining contents are sidecars inside '.openphoto/' (human-authored XMP metadata, possibly orphaned sidecars whose media moved) is therefore treated as empty. Lines 43-44 then permanently destroy that data with `try? FileManager.removeItem(at: .openphoto)` followed by `removeItem(at: url)`. This is a hard delete (not a move to bin), so it violates invariant 3 (nothing hard-deletes) and invariant 2 (human-authored metadata must survive). The `try?` on line 43 also silently swallows any failure. Worse, because the folder is considered empty even when it contains real XMP, a user 'deleting an empty folder' can irreversibly lose curated metadata with no warning and no recovery path.
  - Verifier verdict: The sole caller deleteFolder (AppState+FolderReorg.swift:262) first bins all media recursively, and BinStore.moveToBin (BinStore.swift:29-35) moves each file's .openphoto/<name>.xmp sidecar into the recoverable bin alongside it; deleteEmptyFolder also throws notEmpty (line 40) if any real media file is still physically present, so curated metadata for present assets is never hard-deleted. The only thing lines 43-44 can destroy is a true orphan sidecar (xmp with no media), which the format spec (line 113) and the code itself (VaultReorganizer:89, "stale sidecar... garbage") treat as an invalid/garbage state, so this is at most a minor cleanup wart, not Critical loss of human-authored metadata.
- **embed() deletes the original before moving the rewritten file in — crash-mid-write loses the original** (Scanner, Presence, Media, auditor said Critical/file-integrity) — `Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift:69-71`
  - Auditor's concern: embed() writes the new image to a sibling temp, then does `fm.removeItem(at: url)` (the ORIGINAL user media) and only afterwards `fm.moveItem(at: tmp, to: url)`. If the process crashes, the volume fills, or the move fails between the remove and the move, the original is gone and the temp is left under a UUID-prefixed name — the user's original photo is destroyed. This violates hard invariant #4 (all writes atomic: temp -> fsync -> rename) and invariant #1 (originals never modified without care). Note the rest of the codebase routes vault-state writes through AtomicFile.write which uses replaceItemAt; this in-place media rewrite does not. The temp is also created in the same dir with `UUID + '-' + originalName`, so on failure it is an orphan that won't be cleaned up.
  - Verifier verdict: The remove-then-move at lines 69-71 is real and non-atomic (unlike AtomicFile.write's replaceItemAt), but all three callers (Takeout/Photos/Volume sources, via ImportEngine line 86-88) run embed() on a freshly-fetched copy in a UUID-named staging dir, never on the user's source original (src/SD card/Photos library are untouched). A crash mid-write loses only a re-fetchable staging copy inside a do/catch, so no irreplaceable original is destroyed — this is a Low-severity atomicity hardening nit, not a Critical data-loss bug.
- **Per-file scan loops lack autoreleasepool — residual unbounded memory growth (the OOM shape)** (Scanner, Presence, Media, auditor said High/memory) — `Sources/OpenPhotoCore/Scanner/Scanner.swift:29-53`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:63-85`, `Sources/OpenPhotoCore/Scanner/Scanner.swift:91-122`, `Sources/OpenPhotoCore/Media/MetadataExtractor.swift:59-81`
  - Auditor's concern: ContentHash.ofFile, EmbeddedMetadata.read, and extractImage each pool their own ImageIO/FileHandle temporaries, but the SCAN LOOP BODIES themselves are not wrapped in autoreleasepool. Each iteration creates autoreleased temporaries that are NOT covered by those inner pools: the walk loop bridges resourceValues/NSString per file (lines 29-53); the extract loop does `JSONEncoder().encode($0.tags)` -> String bridging, AssetRecord construction, and `(entry.path as NSString)` bridging (lines 102-122). Crucially extractVideo (MetadataExtractor.swift:59-81) uses AVURLAsset and `await asset.load(...)` with NO autoreleasepool at all — Core Media/AVFoundation temporaries from duration/track/metadata loads accumulate. Because the whole scan runs inside one detached Task with no enclosing per-file pool, these temporaries are only drained when the entire scan returns. On a large library this reproduces the 41 GB-style growth at a lower constant. (The value arrays found/aligned/newAssets/pairCandidates also grow O(N) for the whole library, but those are small structs; the autorelease accumulation is the dominant risk.)
  - Verifier verdict: The three dominant memory consumers are already wrapped in autoreleasepool by commit 4cc805f: ContentHash.ofFile pools each 1MB chunk (the ~1.5GB/video driver), and extractImage/EmbeddedMetadata.read pool their ImageIO sources+CFDictionaries — these were the 41GB OOM cause and are fixed. The cited loop-body temporaries are small and mostly ARC-managed Swift natives (URLResourceValues struct, Swift Strings, a tiny JSONEncoder().encode of tags, AssetRecord structs intentionally retained O(N)), not large autoreleased CF/NS buffers; the (entry.path as NSString) bridge is at line 137 in the step-5 instances map, not the extract loop. extractVideo genuinely has no pool but cannot use a synchronous one across its awaits, and its per-file AV loads (duration/naturalSize/a few strings) are small — there is no demonstrated unbounded accumulation of OOM magnitude, making this a Low defensive hardening item (already tracked as task #17), not a confirmed High defect.

---

## Appendix B — Subsystem health notes

_One-paragraph read per subsystem from its two auditors._

**Catalog & schema** — On the Correctness & Safety lens this subsystem is in good shape. There are no force unwraps, try!, or as! anywhere in the Catalog files; SQL is consistently parameterized (no string-interpolated user values — only safe internal fragments like LIMIT/qmark-lists), so injection is not a concern. Migrations v1..v12 are append-only and idempotent (v3's drop+recreate of vault_presence is self-contained and documented as a rebuildable cache), and the Float16/dHash/Int64 encode-decode paths round-trip losslessly under normal data. Transaction boundaries are correct — each multi-statement mutation (purge, setCanonical, setLivePair, etc.) runs inside a single dbQueue.write block. The real defects are narrow edge cases: a silent Float16 truncation that can misalign the semantic-search matrix on a corrupt blob (memory-unsafe out-of-bounds read), an orphaned-people gap after a local-vault purge, and a GLOB-metacharacter blind spot in presence-path rewriting that re-introduces the exact phantom-folder bug that function exists to prevent. On the Structure & Experience lens the Catalog layer is in good shape. SQL is consistently bound (the only string interpolations are an Int `LIMIT`, fixed enum-derived `stage`/`kind` strings, and GRDB-generated `?` placeholder lists — no injection vector), FTS5 terms are correctly quote-escaped, migrations are append-only/idempotent, and the SwiftUI consumers correctly treat `Catalog` as a plain dependency inside an `@Observable` `AppState` rather than an `ObservableObject`, loading data off-main in most hot paths (`MapView`, `loadPeople`, cull groups all use `Task.detached`). ForEach call sites use stable identity (`instanceID`, `.id`). The findings are a small cluster of efficiency-and-maintainability issues: face fetches always decode embedding blobs that every UI consumer discards; the `people()` query can surface ghost zero-face cards; and there is some duplicated Float16/SQL boilerplate and stale documentation. None are crashes or data-loss; the highest-impact item is the embedding over-fetch on large people, which is a real per-person scale cost.

**Queries & Search** — On the Correctness & Safety lens, this subsystem is mostly solid: the timeline UNION SQL is fully parameterized (no string-interpolated dirPath), GLOB folder matching avoids LIKE wildcard pitfalls, OCR/caption/tag LIKE terms are properly escaped, and runSearch correctly pushes all heavy SQL + Accelerate + Core ML work off the main actor via Task.detached, so there is no main-thread blocking and no obvious data race. The two genuine concerns are: (1) SemanticIndex builds its row-major fp32 matrix trusting the DB's declared `dim` integer rather than the actual decoded `vector.count`, so a short/truncated embedding blob (or a Float16-unpack that fell short) silently misaligns the matrix and drives vDSP_mmul to read out of bounds — a potential crash/garbage-results path the existing model-mismatch guard does NOT cover; and (2) error swallowing is pervasive — the whole search path (runSearch, textMatches) wraps every DB/FTS call in `try?`, so a malformed FTS expression, DB corruption, or any query failure degrades to silently-empty or partial results with no user-facing error state. Lesser items: DatePreset force-unwraps Calendar.date results (crash on exotic calendars/year math), and the IN(...) host-parameter fan-out in items(forHashes:)/structuredFilter has no chunking against SQLite's variable cap for very large libraries. On the Structure & Experience lens this subsystem is broadly healthy: the SQL helpers are parameterized (no path/string injection — dirPath and all user values go through bound `?` placeholders or GLOB args, LIKE/FTS terms are escaped), the SwiftUI layer uses correct property wrappers (`@Observable` AppState bound via `@Bindable`, facets loaded once in `.task`, grid is a `LazyVGrid` keyed by stable `instanceID`), and the ranker is a pure, testable function. The notable defects are (1) a search-result race: every filter tap / submit fires an unstructured, un-cancelled `Task`, so overlapping searches can publish out of order and the wrong result set can win; (2) scale concerns where loose filters or the empty-query path materialize the entire library into Swift arrays / a giant `IN (?,?,…)` bind list, with errors silently swallowed by `try?`; and a few maintainability items (duplicated drive-dedup SQL, swallowed errors hiding real failures). None are crashes or data-corruption on their own, but the race and the unbounded `IN` list will be user-visible on the planned 10k-photo libraries.

**Vault, IO, Hashing** — The subsystem is mostly solid on the correctness/safety lens: the streaming hasher is genuinely constant-memory (per-chunk autoreleasepool), file handles are reliably closed via defer, copies are hash-verified before being trusted (VerifiedCopy), and the never-overwrite discipline is consistently applied on the copy path. However there are two real data-loss/durability defects against the hard invariants. First, AtomicFile (the single funnel for every vault-state write) does NOT actually deliver the durability its own doc comment claims: it calls fh.synchronize() (plain fsync, not F_FULLFSYNC) and never fsyncs the parent directory after the rename, so a crash/power-loss can lose the rename or leave a zero-length file even though write() returned — this weakens invariant 4 for manifest.jsonl, vault.json, sidecars and the bin log. Second, VaultReorganizer.deleteEmptyFolder hard-deletes the folder's .openphoto/ directory (which holds human-authored XMP sidecars) with removeItem, violating both the never-hard-delete invariant (3) and the "human metadata is precious" invariant (2). Beyond those, BinStore move/restore can silently no-op (swallowed at call sites) when the bin or live path is already occupied, and folder names typed in the UI are not sanitized for ".." traversal. The hashing and Manifest/ContentHash parse paths are clean. Through the Structure & Experience lens this subsystem is mostly clean and well-factored: the SwiftUI surface that consumes it (BinView/AppState) uses the correct property wrappers (@Observable AppState, @Bindable, LazyVGrid with stable Identifiable ids, off-main thumbnail decode), so I found no SwiftUI defects. The design itself is small and cohesive. The real weaknesses are in robustness and scale of the JSONL stores: both Manifest.read and BinStore.list() abort the entire file on a single malformed line, and because most call sites swallow that with `try? ... ?? []` a one-byte corruption silently presents the vault (or bin) as empty rather than as an error. Performance-wise the bin log is rewritten in full on every single move-to-bin/restore (O(N^2) for batch deletes) and re-parsed from disk for every vault on each of ~24 refreshQueries() sites, with no caching. A few smaller design issues (restore filter removing all same-path entries, no collision handling on restore, a redundant non-lenient ISO8601 parser) round it out. Nothing here is a security/privacy hole.

**Scanner, Presence, Media** — The subsystem is mostly careful about the issues it was previously burned by: ContentHash streams with a per-chunk autoreleasepool, and EmbeddedMetadata.read / extractImage each wrap their ImageIO temporaries in a pool. But two real correctness/safety gaps remain on this lens. First, the OOM regression is only partially fixed: the three per-file scan loops in Scanner.scan (walk, hash, extract) have NO autoreleasepool around the loop body, so the autoreleased temporaries created outside the inner helpers (resourceValues bridging, JSON tag encoding, AssetRecord/NSString bridging) plus the always-pumped extractVideo AVFoundation path accumulate across the whole library — exactly the shape of the 41 GB blowup, just at a lower constant. Second, EmbeddedMetadata.embed deletes the original file before moving the rewritten temp into place, which is a non-atomic, crash-mid-write data-loss window on a user's original media (violates hard invariant #4). Beyond those, there is a force-unwrapped FileManager.enumerator() that crashes on an unreadable root, a manifest fast-path that can silently miss same-size/same-mtime content edits, and several swallowed-error paths that quietly drop files or metadata. Concurrency is generally sound (sequential scans, owned watcher), with only minor isolation nits. On the Structure & Experience lens this subsystem is in fairly good shape: the core types are small, value-oriented, Sendable, and well-tested (every risky area — Scanner, LivePhotoPairer, MetadataExtractor, EmbeddedMetadata, PresenceService, FolderWatcher, BackupProbe — has a dedicated test file, so "missing tests" is not a concern). The real lens findings cluster around performance and design rather than SwiftUI. The dominant performance issue is the single-threaded scan pipeline (serial walk + serial hash + serial per-file metadata extract) combined with PresenceService's query-amplifying design: each locations() call re-runs registeredVaults() and a full vaultPresenceHashes() set-fetch per drive vault, and onlyOnThisMac() invokes that once per item, so a multi-select eviction does O(items × vaults) full-set SQL reads. PresenceService.locations() is also called synchronously inside the Inspector's SwiftUI body. On maintainability, BackupProbe is now dead production code (zero callers, explicitly superseded by PresenceService) that duplicates PresenceService's isOnlyOnThisMac/onlyOnThisMac API, and LivePhotoPairer's last-write-wins dictionaries make pairing depend on non-deterministic filesystem enumeration order. The force-unwrapped fm.enumerator()! in Scanner is a latent crash point. No security/privacy issues were found in these files.

**Import (foreign / PhotoKit / Takeout / camera)** — On the Correctness & Safety lens this subsystem is in good shape. The core integrity guarantee holds: the engine independently hashes every staged copy and only records/imports an item once the scanner's recomputed manifest hash matches, so no unverified or half-written file is ever trusted in the vault, staging is on the same volume (moves are atomic renames), and the staging temp dir is removed via `defer`. Concurrency around the genuinely racy CameraSource (shared ICC delegate queue, single-flighted enumeration, lock-then-resume continuation discipline) and PhotosLibrarySource (ResumeOnce for opportunistic double-callbacks) is carefully done. The notable risk is in the deletion-eligibility / "already imported" judgement, which is made on a metadata fingerprint (`sourceKey|name|size|takenAt`) of the on-device file rather than its content hash — a collision can mark a never-imported original as safe to delete from the phone, an irreversible off-device data loss. Secondary issues: a handful of `Dictionary(uniqueKeysWithValues:)` calls that trap on duplicate keys, errors swallowed via `try?` in the metadata-fold and registry-append paths, no real cancellation path for an in-flight import, and `EmbeddedMetadata.embed` doing a non-atomic delete-then-move that can momentarily destroy the staged file (cleanly caught downstream, but the failure is silent). On the Structure & Experience lens the subsystem is generally healthy: the SwiftUI import grid is correctly lazy (LazyVGrid), uses stable `\.element.id` identity, and thumbnails flow through a single shared NSCache-backed `ThumbnailImage` loader so there is no per-render re-decode; import sources are cached in `DeviceWatcher.sourceCache` so the `@State source` keeps a stable identity. The real weak spots are (1) heavy work recomputed on every `body` evaluation in `ImportView` — `displayItems` re-filters the whole item list (and for foreign vaults runs an O(items × checkedFolders) prefix scan) and is evaluated several times per render, while the "in library" / "imported" caches re-pull large catalog Sets and do per-item registry probes that don't scale to the 10k-item foreign drives the design explicitly targets; and (2) maintainability debt — EXIF-date reading, the CGImageSource thumbnail option dictionary, and the read-only `delete()` stub are duplicated across VolumeSource/TakeoutSource/ForeignVaultSource/PhotosLibrarySource, and the Takeout/Photos "(edited)" naming + JSON-matching logic is fragile and untested for collision cases. No SwiftUI property-wrapper misuse, view-identity, or injection holes were found. Privacy exposure is limited to full filesystem paths embedded in `sourceKey` and raw `String(describing: error)` strings surfaced into the UI/registry.

**Sync (one-way, drift, deletion propagation)** — On the Correctness & Safety lens this subsystem is mostly solid and unusually careful about the hard invariants: VerifiedCopy never overwrites and always re-hashes the temp before the atomic rename (it even fsyncs), the bin-then-replace ordering in repairCorrupt and the move-then-manifest ordering in deletion propagation are genuinely crash-safe (an interruption self-heals as recoverable drift), free-space is guarded before copying, and deletion eligibility correctly keeps an intent pending while any other drive still holds the hash. The real weaknesses are around partial/interrupted reads of passive drives and silently-swallowed errors: a drive yanked mid-walk causes the drift scanner to report still-good files as "missing/changed" and then overwrite vault_presence with the truncated set, surfacing phantom lost photos; manifest reads abort entirely on a single corrupt JSONL line (no per-line tolerance) so one bad byte can make a whole drive look empty and re-trigger mass copies; and several failure paths (final manifest rewrite in apply, every snapshot/peek/import path) use try?/catch{} that hide errors with no user-facing state. None of these hard-delete originals or violate one-way flow, but they can corrupt the derived presence/manifest view and silently drop work. There are no force-unwrap crashes on the hot paths and no data races (the engine is a value type dispatched via Task.detached, catalog writes are serialized through GRDB's dbQueue). On the Structure & Experience lens, the Sync subsystem is mostly healthy. The core pure functions (BackupStatus, CanonicalManagement, DriveKind, DriveVolume, SyncPlan, VerifiedCopy) are small, well-factored, and each has a dedicated test file — coverage here is unusually good. SwiftUI usage is largely correct: the sheets use @Bindable AppState, .task for off-appear loading, and stable list identities. The notable problems are all performance/consistency: (1) the bulk drift-repair paths (adoptAll, restoreAllRecoverable, repairAllRecoverable) call DriftReconciler.writeManifestEntry once per file, and each call re-reads + atomically rewrites the ENTIRE manifest — O(findings × manifest) full rewrites; (2) goodCopyURL re-opens and linearly scans every connected drive's whole manifest from disk once per finding inside those same loops; (3) the adopt/restore/acknowledge user paths run synchronously on the @MainActor (file hashing + manifest rewrites on the main thread), inconsistent with the repair/verify paths which correctly use Task.detached. There is also meaningful duplicated diff/sidecar logic between SyncEngine.plan and planClone and between DeletionPropagator.propagate and deleteDriveOnly. No SwiftUI property-wrapper misuse, view-identity bugs, or security/privacy issues were found in this subsystem.

**Send (device/volume copy-out)** — On the correctness-and-safety lens this subsystem is largely sound: the volume copy path hash-verifies every written file against the source content hash before confirming, removes partial copies on any failure, fsyncs to the physical device before verifying, and uses collision-free naming so it never silently overwrites an existing destination file. Registries are NSLock-guarded and rewritten atomically, and the heavy I/O (enumeration + hashing) runs off the main actor because SendEngine.run is a non-isolated async method. The real gaps are at the edges: there is no free-space preflight before a multi-gigabyte copy (every other copy path in the codebase has one), enumeration failures are swallowed in a way that silently disables live dedup and re-copies everything, a fsync that cannot even be opened (FileHandle init fails) silently bypasses the durability check, DeviceRegistry can silently drop a record on a per-entry encode failure, and enumeratePresent re-hashes every file on the volume with no per-file autoreleasepool and no cancellation check. None corrupt data, but several produce wrong/duplicate results or wasted work users will hit on real hardware. Continuation: findings 4 to 6 for the Send subsystem.

**Derivation / ML pipeline** — The pipeline is mostly defensive on the crash axis: it leans hard on optional-returning init (`CLIPTokenizer.init?`, `EmbedStage` lazy load), graceful `nil` degradation, and the few force-unwraps in `CLIPTokenizer.bytesToUnicode` are provably in-range. Concurrency is sound at the model-handle level (NSLock-guarded lazy load; stages run serially via awaited `Task.detached`, GRDB serializes catalog writes). The real exposure on this lens is memory/resource discipline under the 42k-asset run and swallowed errors. The biggest concrete risk is the total absence of `autoreleasepool` anywhere in the per-image loop or stage bodies — full-resolution `CGImage`/`CGImageSource`/`CFData`/`CVPixelBuffer` allocations decoded per asset are autoreleased and never drained between iterations of a detached async task, which is the same failure mode that previously OOM'd indexing to 41GB. Secondary issues: every catalog write in every stage is `try?`-swallowed so a failing write silently marks the job "derived"; OCR/Face/PHash decode the source at full resolution (Face must, but OCR/PHash could downsample sooner); and `EmbedStage()` is reconstructed per semantic search at the call site, recompiling/reloading the text Core ML model on every query. The `gunzip` buffer is sized from the gzip ISIZE field, which silently truncates if the uncompressed stream ever exceeds it — safe for the fixed vocab today but a latent correctness trap. On its own (OpenPhotoCore) the pipeline is clean and well-factored for my lens: each stage is a small, single-responsibility DerivationStage; the tokenizer/embedder/geocoder are pure value-ish types with no SwiftUI coupling, no per-render work, and good unit-test coverage. The real defects in the Structure & Experience lens live at the seam between these stages and the @Observable @MainActor AppState. Two issues stand out: (1) the search path constructs a brand-new EmbedStage on every query, which throws away the per-instance lazy-model/tokenizer memoization and recompiles the Core ML text model and re-parses the 1.36 MB gzip vocab from scratch each search; (2) the stage registry is a stored property whose inline initializer eagerly loads the entire 8.3 MB / 33.8k-line GeoNames table synchronously on the main actor during AppState() construction, blocking app launch. Both are caused by the same structural gap — there is no shared, dependency-injected home for these expensive-to-build model handles, so callers keep re-instantiating them. The remaining items are lower-severity design/maintainability notes (no autoreleasepool across the 42k drain loop is in the memory auditor's territory but worth flagging at the structure level, GeoNames whole-file-in-RAM, and a minor dedupe/coupling note).

**Cull & Faces (clustering/dedup)** — On the Correctness & Safety lens this subsystem is largely solid: the pure functions (BurstGrouper, DuplicateGrouper, PerceptualHash, FocusMeasure) defend their boundaries well — cross-dim vectors return cosine/dot sentinels instead of crashing, dHash/varianceOfLaplacian fix tiny working buffers, the union-find is correct, and Hamming uses nonzeroBitCount on bit-pattern conversions (no signedness bug). The headline correctness risk is KeeperSelector.suggestion's force-unwrap of `c.max(by:)!`: it is guarded by a precondition rather than the input contract, so an empty group becomes a hard crash, and the precondition itself fires in release-with-checks. The dominant safety risk is concurrency/complexity: FaceClusterer is O(n²·dim) single-link with no cancellation, fed by an unbounded `unassignedFacesWithEmbeddings()` (no LIMIT) — on a fresh 10k-photo import (tens of thousands of unnamed face crops × ~2048-float feature prints) this is a multi-minute, multi-GB detached compute that the known chaining bug also turns into one garbage mega-cluster. loadPeople()/loadCullGroups() store no Task handle and never check Task.isCancelled, so rapid tab switches stack overlapping detached jobs and apply stale results last-writer-wins. Errors throughout are swallowed via `try?`/`?? []`, so a corrupt catalog read silently presents an empty Cull/People view with no user-facing error state. No data-loss or file-integrity issue exists in these files (they are read-only analyzers; eviction happens elsewhere). On the Structure & Experience lens the subsystem is mostly tidy: the core algorithms are pure enums (good for testing), clustering/grouping runs off-main via Task.detached, and the lists in the two consuming views (PeopleView, CleanupView) use LazyVGrid/LazyVStack with stable, deduped identities. The real weaknesses are scalability and per-render recomputation. FaceClusterer is O(n^2) greedy single-link over the entire unassigned-face population (its doc's "bounded and shrinking" assumption is false on a first run of a large library), and DuplicateGrouper is O(n^2) per folder with a union-find that lacks path compression / union-by-rank. CleanupView recomputes several whole-collection derived arrays (orderedSelectable, allItems, allSuggested, groupsSignature) on every body render and does O(n) firstIndex lookups per tap/rubber-band tick, so a multi-thousand-tile tidy session will churn. Two detail views run synchronous catalog DB queries on the main actor inside onAppear (PersonDetailView.reload / ClusterDetailView.reload). There are also a few small design smells: allocating an EmbedStage just to read a constant modelID, and duplicated max(by:) tiebreaker logic. No security/privacy issues found in this subsystem.

**LibraryService, Sidecar, Interop, Selection** — On the Correctness & Safety lens this subsystem is mostly solid: concurrency is clean (LibraryService is a genuinely immutable Sendable class delegating mutation to a serialized GRDB DatabaseQueue; SelectionModel and the sidecar/interop types are pure value types with no shared mutable state, no retain cycles, no main-thread file I/O on @MainActor — the async LibraryService methods are nonisolated and run off-main). The FaceRegion Vision<->MWG coordinate math round-trips correctly, atomic writes go through a correct temp->fsync->rename helper, copies are hash-verified, and the folder-move "no folder into its own descendant" guard exists and is correct (VaultReorganizer.moveFolder). The one Critical issue is a human-metadata data-loss path: LibraryService.updateMetadata rebuilds SidecarData with an empty faces array and overwrites the sidecar, silently destroying confirmed face regions that other code carefully read-modify-writes. Secondary issues are sidecar/catalog divergence when a sidecar becomes empty, inconsistent try/try? handling in the delete batch that can abort mid-loop leaving disk and catalog out of sync, an XML-illegal-control-character serialize path that can produce an unparseable sidecar, and a tag-sync baseline that is persisted even when the Finder-tag writes that justify it failed. On the Structure & Experience lens this subsystem is mostly healthy. The SwiftUI consumers of the value-type SelectionModel use the right wrappers (@State for the model, @Binding into RubberBandModifier, @Bindable for AppState), folderTree/timelineSections are computed once into observable state rather than per-render, and the folder-move guard (root via !src.isEmpty, descendant via dstParent == src || hasPrefix(src + "/")) is present and correct in VaultReorganizer. Test coverage over the risky areas (XMP, regions, selection, undo, tag-merge, move, eviction, reorg) is solid, and there is no sensitive-data logging in the audited files. The real findings are performance/scale: a synchronous (non-async) human-metadata + Finder-tag write path that does multi-file disk I/O on the main thread during an inspector save; an eviction/rehydrate verification path that re-fetches the entire vault_presence table and linear-scans it once per item per drive; and a rubber-band selection model that re-scans the full item list on every drag tick (and every 16ms during auto-scroll). There is also some duplicated XMP-serialize-and-atomic-write logic and a leaky raw-error string in the move-failure surface. None are data-loss/security holes; the highest-impact ones are main-thread I/O and the O(items x drives x presenceRows) eviction verification.

**AppState (god object)** — On the Correctness & Safety lens, AppState is mostly disciplined about heavy work: the genuinely expensive jobs (search index build, embeddings, face clustering, drift verify, sync, sidecar writes) are correctly pushed off the MainActor via Task.detached, sidecar helpers are nonisolated, LibraryService/Catalog are Sendable with a serialized DatabaseQueue, and closeLibrary does a thorough state reset including registry/closure teardown and derivationTask cancellation. There are no force unwraps of library!, no try!/as!. However, two real main-thread-blocking hazards remain: refreshQueries() runs full-library SQL plus a full filesystem directory walk synchronously on @MainActor and is called pervasively, and drainDerivation()'s per-item loop performs synchronous catalog writes plus two full-table COUNT(*) progress queries on @MainActor for every asset. The derivationTask lifecycle has a clobber race across close/open, removeOpenedItem navigates the wrong list, and the people-management detached tasks have an unserialized read-modify-write window on sidecars. The pervasive try?/(try? …) ?? [] idiom silently swallows load failures, which can present as a spuriously empty UI with no error surfaced. AppState is a ~1740-line @Observable @MainActor class that owns essentially every cross-cutting concern in the app (library lifecycle, timeline/folder queries, search, people/faces, cull, drives/sync/drift, presence, undo, device watching, Finder-tag sync, sidecar writes). On the Structure & Experience lens it is functionally careful — captures are consistently [weak self], the heavy services it hands to detached tasks are Sendable, closeLibrary clears watcher closures and cancels derivationTask, and the big SwiftUI grids use LazyVStack/LazyVGrid with stable IDs. The real problems are (1) a few hot paths do synchronous DB + file I/O on the MainActor inside view body / per-item loops (presence resolution in the inspector, combinedProgress() during derivation), (2) the async load methods (loadPeople/loadCullGroups/runSearch/reverify/etc.) publish results back to @Observable state without re-checking that the library is still the same one or that the task wasn't superseded — so a library switch or rapid retrigger can bleed stale results into a new library or clobber newer results, (3) the facesDirty/geocodeDirty "dirty" flags are write-only dead state that the People reload path ignores, and (4) the class itself is an extreme god object that couples the whole app to one observable, amplifying both the recomputation cost and the blast radius of any change.

**AppState extensions (folder reorg, undo)** — On the Correctness & Safety lens the subsystem is mostly sound: there are no force-unwraps/try!/as! that can crash, the self-descendant and root-immovable guards are enforced at both the UI and the VaultReorganizer layers, and the undo path is genuinely data-only (it only replays existing, stale-safe ops with inverse arguments). The two real problems are (1) a confirmed unsynchronized-writer race between MainActor folder/photo reorg ops and the off-main background scan, which can silently revert the manifest portion of a move (disk moved, manifest left pointing at old paths) — there is no `scanning` gate anywhere on the reorg entry points; and (2) a confirmed false "Couldn't undo Move" alert for any Live Photo, because the hidden paired video is recorded as a moved file but its instanceID can never resolve in `items(instanceIDs:)` (it is filtered out by `isLivePairedVideo = 0`), inflating the unresolved counter on an otherwise-successful undo. Beyond those, drive-propagation failures are swallowed by `try?` by design (drives are passive/best-effort), but the same `try?` pattern on the *local* enqueue/presence/catalog writes hides real catalog-desync conditions from the user with no surfaced error. A minor undo re-entrancy window also exists. On the Structure & Experience lens these two extensions are mostly sound: the undo descriptors are clean value types, the drag/drop callers use stable identity (FolderNode.id == path), and the @MainActor/@Observable usage is correct. The real weaknesses are maintainability and a few experience edge cases: the drive-relpath/parent-path mapping is triplicated (two private instance helpers plus two free functions plus an acknowledged copy of SyncEngine.driveRelPath), error handling is inconsistent (a handful of ops alert while the entire drive-propagation/offline-queue/presence-rewrite path is uniformly try?-swallowed, so structural divergence between Mac and drives can occur with zero user signal), and there is no re-entrancy guard so two overlapping drags (or a drag during an in-flight scan) can interleave through the many await suspension points. There is also a latent view-state side effect: refreshQueries auto-expands the entire tree whenever expandedFolders becomes empty, which deleteFolder can trigger. None are crashes; the highest-impact items are the silent-divergence error pattern and the re-entrancy gap.

**Media UI (tiles, viewer, timeline, peek)** — On the Correctness & Safety lens this subsystem is largely solid: the thumbnail loader correctly guards against view-reuse stale images via a `.task(id: cacheKey)` key and a post-await `key == cacheKey` recheck, the shared NSCache is bounded (countLimit 6000), thumbnail decode is genuinely off the main thread (detached task + downsampled CGImageSource), and the AVPlayer teardown bug (lingering/doubled audio) is properly fixed (`pause()` + `replaceCurrentItem(nil)` + nil). The force-unwraps of `state.library!` in ViewerView/TimelineView/PeekView are gated by RootView's `state.library == nil` branch, so they don't fire in normal flows. The real defects are concentrated in full-resolution still decoding on the main thread (the entire file is read into memory then NSImage is force-decoded to a CGImage synchronously during the SwiftUI view update for both the viewer and peek), an unbounded-memory full-image load with no size cap or autorelease management, and several smaller correctness gaps (silently-swallowed full-res read/decode errors with no user-facing failure state in the main ViewerView, an `AVPlayer(url:)` created against a possibly-nonexistent/huge URL with no error surface, and a video-with-no-player dead-end). None are crashes; the most serious are main-thread stalls and unbounded memory on large originals. On the Structure & Experience lens this subsystem is mostly well-built: SwiftUI identity is consistent and stable (instanceID/PeekItem.id keys, sectioned LazyVStack/LazyVGrid/LazyHStack with laziness everywhere), thumbnail decode is correctly off the main thread with a shared NSCache and proper `.task(id:)` reuse-guarding that fixes the recycled-cell stale-image bug, and AppState is a single `@Observable @MainActor` source of truth wired with `@Bindable`/`@State` appropriately. The notable issues are: (1) a real cross-context correctness/UX bug where the shared "delete then advance" path navigates the wrong list when the viewer was opened from Folders/Search/People/Map; (2) the AVPlayer-teardown fix that exists in ViewerView was never propagated to PeekViewer (duplicated, un-shared viewer/player logic), reintroducing the lingering/doubled-audio leak in peek; (3) full-image decode (NSImage(data:) + cgImage) still runs on the main actor in both viewers; (4) per-render O(n) re-scans of the 10k-item timeline list in TimelineView.body; and (5) the already-known per-tile GPU-texture blowup driving dense-grid lag. None are data-corrupting, but (1) and (2) are user-visible.

**Folders, Map, People UI** — On the Correctness & Safety lens, the subsystem is mostly sound: error-swallowing `try?` paths degrade gracefully to empty arrays (no crashes), the SelectionModel/ForEach identity keys are well-chosen, FaceClusterer never emits empty groups (so the `ids.first ?? 0` fallback is safe and cluster ids stay unique), and the known shared/blank-pin recycling bug is already handled in ThumbnailImage. The real defects are concurrency-shaped: People detail/cluster reloads run N synchronous catalog queries (one DB round-trip per face) directly on the @MainActor in `.onAppear`, which will jank or freeze the UI for people with many faces. MapView regenerates a fresh `UUID()` for every cluster on every pan/zoom, destroying SwiftUI annotation identity and forcing full annotation/thumbnail teardown on each camera change. There are also a handful of `state.library!` force-unwraps that crash if the library is torn down (closeLibrary) while a grid/sheet is on screen, and the cluster sheet shows stale items for a frame because `sheetItems` is never reset between opens. None are data-loss/corruption risks; the file-integrity invariants are respected in this UI layer. Through the Structure & Experience lens (SwiftUI correctness, performance/scale, security/privacy, maintainability), the subsystem is mostly sound on property-wrapper usage (consistent @Bindable on the @Observable @MainActor AppState, @State for local UI), lazy grids with stable identity, and off-main heavy work via Task.detached. No security/privacy issues were found (no Keychain/UserDefaults misuse, no sensitive logging, no injection from external input in these files). The real risks are concentrated in Map and People: MapView regenerates a fresh UUID for every cluster on each recluster, so panning/zooming tears down and rebuilds every annotation and reloads every pin thumbnail (flash + cost); the cluster sheet renders the previously-selected cluster's photos until the async query returns; programmatic map animations re-trigger reclustering through onMapCameraChange; and FaceCropView does its CGImage crop back on the main actor with no cache of the cropped result, so scrolling a large People grid repeats fetch+crop per card. PeopleOverview also never re-reads the facesDirty flag, so a background face drain leaves the overview stale until both lists happen to be empty. The remaining items are smaller perf/maintainability nits (per-render tree walks, O(n·m) zoom filter, an untested clustering function, duplicated root-drop handling).

**Search UI, Inspector, Cleanup, Selection UI** — On the Correctness & Safety lens this subsystem is mostly sound, but the Inspector has two genuinely user-facing problems. First, every human-metadata edit (rating tap, favourite toggle, tag add/remove, caption submit) runs InspectorView.save() synchronously on @MainActor, and save() does the full durable write path inline: an XMP sidecar write (temp→fsync→rename), a catalog update, optionally reconcileFinderTags (reads/writes Finder xattrs on every local instance file), and then refreshQueries() which rebuilds timeline sections, the folder tree and bin items. That is unbounded file and DB I/O on the main thread per click, plus all errors are swallowed by try? with no user-facing failure state — a failed sidecar write looks identical to success. Second, in-progress caption / new-tag text that hasn't been submitted is silently discarded when the user switches photos, and there is no debounce or onDisappear flush, so it is a real lost-edit. A separate navigation bug: Inspector Delete/Evict advances within state.flatItems even when the viewer was opened over Search results or one folder (viewerItems), so it jumps to the wrong next photo. The Search debounce, filter include/exclude state machine, DatePreset+UI presets, SelectionModel rubber-band index math, and CleanupView seed/delete flow are all correct. The state.library! force unwraps in SearchView and CleanupView are real but gated by the RootView library-open check, so they are only a latent fragility, not a live crash. Through the Structure & Experience lens, the search/filter layer is generally well-built: the result grid is correctly lazy, search runs off-main with a 300ms debounce, and the include/exclude filter mutation logic is clean (consistent dedupe, toggle, remove helpers) and unit-tested at the SelectionModel/SearchFilters level. The two real problem areas are InspectorView and, secondarily, repeated work. InspectorView performs synchronous Core ML-free but DB-bound work (geocode and multi-query presence lookups) inside its `body`, runs the entire human-metadata save path (sidecar file write + optional Finder-tag reconcile over every instance file + full library re-query) synchronously on the main actor on every star/favorite/tag tap, and silently discards unsaved caption text when the user switches photos. CleanupView's selection re-seed key is membership-insensitive and can leave a stale pre-selection. The remaining items are lower-severity maintainability/coupling issues (duplicated filter-bar helpers, id-less `.task` facet loads that never refresh, and the recentYears offset coupling).

**Drives & Devices UI** — On the Correctness & Safety lens this subsystem is in good shape. The genuinely destructive flows are well-guarded: FreeUpPhoneView only ever deletes items re-filtered through `verifiedOnDevice` (registry-verified library copies), VolumeSource.delete moves to `.openphoto-trash` rather than hard-deleting, CameraSource.delete checks device-gone state, and all repair/restore paths copy from a hash-verified good copy (`repairFinding`/`DriftReconciler`). DeviceWatcher's ICDeviceBrowser/NotificationCenter start/stop is balanced and idempotent, delegate callbacks correctly hop from ICC's background queue onto @MainActor via `Task { @MainActor in }`, callbacks into AppState capture `self` weakly, and thumbnail decoding is downsampled and off-main on a detached task with a bounded NSCache. The defects found are concentrated in two areas: (1) swallowed enumeration errors that leave the user staring at an empty grid with the UI reporting success/"ready"; and (2) re-entrancy in the repair/drift sheets where long-running async repair actions leave their trigger buttons live and show no in-progress state, allowing the same repair to be launched twice concurrently. There are also a couple of low-severity force-unwraps and a count/label edge case. No data-loss or corruption defects were found in the destructive paths themselves. On the Structure & Experience lens this subsystem is generally well-built: property wrappers are correct (@Bindable for AppState, @State for value-type SelectionModel and local UI state, @Environment(\.dismiss)), sheets use Identifiable item-bound presentation to avoid stale context (DriftPresentation), grids are Lazy with stable id, the shared ThumbnailImage handles cell recycling and a memory cache, and destructive flows are gated behind explicit confirmationDialogs with role: .destructive plus disabled-on-empty-selection guards. No sensitive logging, no SQL/path injection in these views, no stale TODO/FIXME. The real weaknesses are performance-at-scale: several views run synchronous DB full-scans and synchronous filesystem I/O on the MainActor (ImportView cache rebuilds; DeviceWatcher.volumesChanged; DrivesView present/adoptable checks), and a recurring pattern of expensive derived collections (displayItems, verifiedOnDevice) being recomputed O(n) several times per body render rather than being cached. These matter for the friend's real ~10k-photo import which is the stated acceptance test. There are also no tests around any of these destructive drive/device flows.

**App shell (entry, window, sidebar, settings, send UI, bin)** — On the Correctness & Safety lens this subsystem is in good shape. The headline risk a reviewer expects here — broken security-scoped access after relaunch — does NOT apply: the app is deliberately non-sandboxed (design spec 2026-06-12 §58-59; ad-hoc codesign with no entitlements), so the path-based root persistence in UserDefaults (AppState.configuredRoots) is correct and there are genuinely no bookmark APIs to get wrong. Sparkle is wired correctly (EdDSA public key + appcast feed injected at package time, build-number versioning), atomic writes go through AtomicFile (temp→fsync→rename), and the bin/empty-bin/restore data layout is correct (bin.jsonl lives beside the bin/ dir, so trashing the dir then writing an empty log is the right order; leaving pending-deletions queued across empty-bin is intentional for one-way drive propagation). The @MainActor.assumeIsolated command actions are safe because AppState is @MainActor and SwiftUI command/button actions fire on the main thread. The real defects are smaller: the Bin "Restore" button swallows its error so a failed restore (e.g. the original path is re-occupied, moveItem throws) silently does nothing with no user feedback — in contrast to Empty Bin which does surface errors via NSAlert. Secondary, lower-severity items: two conditionally-safe but fragile state.library! force-unwraps in Bin/SendSheet, an unbounded self-rescheduling reposition loop in WindowControls if a window never attaches, a stale-bin-log inconsistency if the empty-bin trash succeeds but the log rewrite fails, and a (trivial-cost) synchronous catalog aggregate query on the main actor in Settings. On the Structure & Experience lens the App shell is in good shape. SwiftUI ownership is textbook-correct: AppState and DeviceWatcher are both `@Observable @MainActor`, views consume them via `@Bindable`, lists use stably-identified collections (`SidebarItem` CaseIterable, `ConnectedDevice`/`BinEntry` Identifiable with stable ids), and the only large collection (the bin grid) is lazy. The absence of security-scoped bookmarks is by design — the app is intentionally non-sandboxed (confirmed in the config-root design spec), so plain UserDefaults paths survive relaunch correctly and there is no silent access break. No UserDefaults/Keychain misuse, no injection surface, no sensitive logging, and no stale TODO/FIXME in these files. The findings are a small cluster of real-but-bounded issues: the Bin restore button swallows failures silently (a genuine experience/correctness gap against the "nothing hard-deletes, deletion is reversible" invariant), the Empty-Bin flow reaches around LibraryService/BinStore to manipulate the on-disk bin directly (leaky abstraction that can desync an in-memory bin cache and duplicates atomic-write logic), some per-render recomputation in the Send warning view, and the Sparkle updater being held as a plain `let` rather than `@State`. None are crash- or data-loss-class.

---

## Themes & systemic recommendations

**Pervasive `try?`/silent-error swallowing as the default failure mode.** Across nearly every subsystem, errors are discarded — `try?`, `(try? …) ?? []`, swallowed enumeration/parse/write failures — so load, search, sync, import, and save failures surface as empty results, false successes, or silent desync rather than user-facing errors. This matters because it converts recoverable faults into invisible data-integrity and trust problems: a swallowed final-manifest rewrite loses the record of copied files, a swallowed catalog write is recorded as success, a swallowed device enumeration is presented as a successful empty grid. The structural fix is a typed error-propagation discipline: a single Result/throwing convention that bubbles to a shared user-facing error surface, with `try?` permitted only where a documented fallback is genuinely correct. This subsumes the dozens of "swallowed/silent" findings spanning Search, Sync, Send, Import, Derivation, LibraryService, AppState, Drives UI, Bin, and the manifest/bin-log/snapshot read paths.

**Synchronous DB and disk I/O on the main actor, structurally invited by the AppState god object.** The single ~1740-line `@MainActor` AppState (plus its extensions and the views that read through it) routinely runs full-library DB queries, whole-tree filesystem walks, JSONL parsing, hashing, full-resolution image decodes, and durable metadata writes directly on the main thread — often inside SwiftUI `body`/`onAppear`. This matters because it is the direct cause of launch blocking (eager GeoNames load), viewer/scroll hitches (main-thread decode, FaceCropView per-card crop), and save-path stalls, and it scales with library size. The structural fix is to move Catalog/IO behind an async actor boundary with off-main execution and to decompose AppState into focused services (library, search, derivation, drives, people) so I/O cannot be reached synchronously from a view. This subsumes the main-actor I/O findings across AppState, Inspector, ImportView, People/Map UI, Media UI, Settings, and DrivesView, plus the god-object design findings.

**Missing memory bounding (`autoreleasepool`) and full-resolution decode in per-item loops.** Long-running per-file loops — 42k-asset derivation, scanning, volume re-hash, embedding/pHash/face stages — lack `autoreleasepool`, and several decode source images at full resolution before downsizing, reproducing the OOM shape that previously crashed the Mac. This matters because peak memory grows unbounded across the batch and the full-res viewer load is uncapped, putting the whole machine at risk on large libraries. The structural fix is a shared bounded-iteration helper that wraps per-item work in an autorelease pool with cancellation checks, paired with a downsample-on-decode image-loading utility used everywhere a thumbnail or embedding input is produced. This subsumes the autoreleasepool-absence and full-res-decode findings across Derivation, Scanner, Send, Media UI, and the ML stages.

**Unhardened decode/parse boundaries: trusting length, type, and well-formedness of external bytes.** Code that reads embeddings, manifests, bin logs, snapshots, gzip streams, XMP, and EXIF trusts declared dimensions, exact dynamic types, and per-line well-formedness — so a short Float16 blob yields an out-of-bounds `vDSP_mmul` read, one malformed JSONL line makes a whole manifest/bin log read as empty, a gzip ISIZE mismatch truncates silently, and the XMP writer emits XML-illegal control characters. This matters because these are correctness-and-safety boundaries: some are verified out-of-bounds reads, others silently corrupt the catalog or make a drive look empty. The structural fix is hardened codec/parser primitives that validate length against the declared shape, parse line-by-line with skip-and-report on malformed records, and sanitize on serialize — never trusting external bytes. This subsumes the Float16 unpack, manifest/bin-log/snapshot parse, gunzip, XMP-serialize, and EXIF-type findings.

**No supersession/identity guarding on async work published to shared `@Observable` state.** Overlapping un-cancelled Tasks (search, loadPeople, loadCullGroups, reverify, reorg, map reclustering) publish into shared AppState/view state with no generation token or library-identity check, so stale results clobber newer ones and work bleeds across libraries; the same un-guarded reorg races the off-main scan and can silently revert the manifest. This matters because it produces nondeterministic stale UI, cross-library data bleed, and an actual manifest-reverting data race. The structural fix is a standard async-task pattern: per-operation generation tokens (or a small task-coordinator) plus library-identity stamping checked before any publish, and re-entrancy guards around multi-await reorg/undo flows. This subsumes the race/staleness/generation-guard findings in Queries, Cull & Faces, AppState, AppState extensions, and Map/People UI.

**Duplicated logic instead of shared primitives for format-, path-, and algorithm-level operations.** The same logic is copy-pasted across sites — Float16 pack/unpack, face column-list SQL, XMP-serialize-and-atomic-write, drive-relpath/parent-path mapping (triplicated), diff/sidecar-path logic, EXIF-date/thumbnail-option/read-only-delete across import sources, and present-match in Send — which is dangerous precisely because these touch the normative on-disk format the sovereignty docs depend on. This matters because divergence between copies produces subtle format inconsistencies and makes the "update docs in the same commit as format changes" discipline impossible to honor when there is no single source of truth. The structural fix is to extract shared primitives (a format/codec module, a path-mapping utility, a single sidecar write path, one import-source base) so each format operation has exactly one implementation to document and test. This subsumes the duplication findings across Catalog, Vault/IO, Import, Sync, Send, LibraryService, and AppState extensions.

---

## Coverage notes & suggested follow-up

_From the completeness critic, which re-globbed the tree to find gaps between auditors._

- **Security-scoped bookmark lifecycle is entirely unaudited and the code does not use bookmarks at all.** Library roots and import sources are persisted as raw paths (`AppState.rootsDefaultsKey = "libraryRootPaths"`, `UserDefaults.standard.set(roots.map(\.path), …)` in `AppState.swift:1318`); `addImportSourceViaPanel`/`quickViewFolderViaPanel`/the `NSOpenPanel` grants at `AppState.swift:148/604/627/907` are never persisted as `bookmarkData`, and there is zero `startAccessingSecurityScopedResource` anywhere in `Sources`. If the app is ever sandboxed (it ships via Sparkle and is a candidate for hardened-runtime/notarization), every relaunch in `OpenPhotoApp.swift:18-25` would silently lose read/write access to the user's library — a sovereignty-critical, cross-cutting concern no auditor flagged. A human should verify the current entitlements/sandbox state and the relaunch grant path.

- **App-launch / relaunch and "missing root" recovery is under-audited.** `OpenPhotoApp.swift:18-25` opens the saved root only if `fileExists`, else falls through to Welcome "without forgetting it." No finding examines: what happens when the root reappears on a different mount path, the `forgetLibrary` path (`AppState.swift:1435`), or `switchRoot` collision when `current.standardizedFileURL == newRoot…` (`AppState.swift:1421`). The interaction between a saved-but-offline canonical root and the drive/presence machinery at launch is unexamined.

- **`ThumbnailStore` (Thumbnails/ThumbnailStore.swift) has no findings despite being the linchpin of the offline-browse sovereignty promise.** Its own doc says "Cache survives eviction — that's what keeps offline photos browsable." Yet it is content-addressed by hash with no validation that a cached JPEG actually corresponds to current content, `thumbnail(for:)` swallows generation failures, and there is no cache-size bound, eviction, or corruption handling (a truncated/0-byte cache JPEG from an interrupted write would make an asset permanently unviewable offline). `CGImageDestinationCreateWithURL` writes are not atomic (no temp→rename), unlike the rest of the codebase's hard invariant #4. Worth a dedicated pass.

- **Cross-cutting end-to-end flows that span the subsystem boundaries and could fall between auditors:** (a) **delete → bin → drive deletion-propagation → undo/restore** as one chain — individual findings hit `BinStore` no-op-on-occupied, `DeletionPropagator`, `LibraryService.delete()` mid-loop abort, and undo's false "Couldn't undo" alert, but no one traced a single delete from UI through bin to drive propagation and back through restore to confirm catalog/disk/presence stay consistent across an offline drive that later reconnects (`pending_deletions` + `pending_folder_ops` replay). (b) **app-launch resume of an interrupted scan/derivation** — the OOM-crash history (MEMORY) means a half-finished scan/derivation is the common case; no finding covers whether a relaunch correctly resumes vs. double-processes, or how the manifest fast-path behaves against a partially-written manifest from a killed run. (c) **`AtomicFile` non-durability (already flagged) combined with the manifest/bin-log "one bad line = empty file" findings** is a compound data-availability risk at launch after a crash that no single finding ties together.

- **Concurrency model of the shared `Catalog`/`DatabaseQueue` is assumed, not audited.** `Catalog` is `final class … Sendable` over a single GRDB `DatabaseQueue` (`Catalog.swift:19`). Many findings say "synchronous DB read on the main actor," but none examine queue contention / potential deadlock when a main-actor read races a long off-main derivation write batch on the *same* serialized queue, nor whether any `DatabaseQueue` access happens after `purgeLocalVault`/library teardown (the `state.library!` force-unwrap findings suggest a teardown race that could reach a closed queue).

- **`OCRStage` and `GeocodeStage`/`ReverseGeocoder` are thinly covered relative to the other derivation stages.** OCR (`Derivation/OCRStage.swift`) silently `try?`-swallows its catalog write and returns `false` on any Vision throw with no surfacing; it has a test file but no finding. These feed search, so silent OCR/geocode gaps degrade search results invisibly — the same class of "silent empty results" the search auditor flagged but never connected back to the producers.

- **AirDrop send path (`Send/AirDropDestination.swift`) has no findings and no tests** (only volume/device send was audited). It constructs `NSSharingService(named:.sendViaAirDrop)`, returns `false` silently if unavailable, and its `verifying`-stage dedup/confirmation logic differs from the volume path. Given the "send dedup silently disabled on enumeration failure" finding on the volume side, the AirDrop variant deserves the same scrutiny (does it ever produce false-positive "sent" outcomes that get written to the registry?).

- **Highest-value follow-up checks a human should run next (in priority order):**
  1. Confirm the app's actual sandbox/hardened-runtime entitlements, then relaunch after moving/renaming the library root and after a macOS reboot — verify read/write access survives without security-scoped bookmarks.
  2. Kill the app mid-scan and mid-derivation (the documented OOM scenario), relaunch, and verify no data loss, no double-import, and correct resume — exercises `AtomicFile` durability, manifest fast-path, and interrupted-run state together.
  3. Run a full delete → empty-bin and delete → restore cycle with a drive that is offline at delete time and reconnects later; confirm `pending_deletions`/`pending_folder_ops` replay leaves disk, catalog, and `vault_presence` consistent (no phantom rows, no orphaned bin entries).
  4. Corrupt a `ThumbnailStore` cache entry (truncate to 0 bytes) and unplug the source drive; verify the asset still renders or degrades gracefully rather than becoming permanently unviewable offline.
  5. Exercise AirDrop send to a real device and confirm the `DeviceRegistry`/`SendRegistry` records only genuinely-confirmed sends (no false "sent" on cancel/decline).
  6. Force-feed a manifest and a bin-log with one malformed line each (already known-real), then confirm launch/scan behaviour end-to-end — not just the unit-level parse — to size the blast radius of "whole file treated as empty."
  7. Drive concurrent main-actor catalog reads against an active off-main derivation write batch on a large (40k+) library to surface `DatabaseQueue` contention/UI stalls and any teardown-time access to a closed queue.
