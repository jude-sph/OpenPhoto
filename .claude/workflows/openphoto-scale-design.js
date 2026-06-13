export const meta = {
  name: 'openphoto-scale-design',
  description: 'Read-only audit of OpenPhoto for time/space complexity (scaling) + structural design, plus a tile-system optimization plan',
  phases: [
    { title: 'Map', detail: 'scale model + hot-path + index-coverage inventory' },
    { title: 'Tile', detail: 'tile pipeline deep-dive → small-tile optimization plan' },
    { title: 'Audit', detail: 'complexity + design lenses per subsystem' },
    { title: 'Verify', detail: 'adversarially check every Critical/High complexity & design claim' },
    { title: 'Synthesize', detail: 'scaling narrative + target architecture' },
  ],
}

const ROOT = '/Users/jude/Documents/projects/OpenPhoto'

const SCALE = `Shared scale vocabulary — use these symbols in every complexity claim:
- N = catalogued assets/instances (typical 10k; power-user 100k; stress 1M)
- M = manifest entries in a vault (~N per vault)
- F = number of folders in the library; V = number of vaults; D = connected drives
- E = stored embeddings (~N once derived; each 512 dims)
- P = items in the CURRENT view/grid; T = tiles visible on screen at min zoom (dense grid → many hundreds)
- K = current selection size; B = bin entries
Express both TIME and SPACE as big-O in these symbols, name the dominant term, and state the realistic library size at which it becomes a user-visible problem (the "cliff") with the concrete symptom (hang, beachball, OOM, dropped frames).`

const PRIMER = `OpenPhoto is a native macOS photo manager (Swift 6 / SwiftUI / SwiftPM). Two targets: OpenPhotoCore (domain logic — vault format, GRDB SQLite catalog, scanner, ML derivation, import/sync/send; depends only on GRDB) and OpenPhotoApp (SwiftUI + a central ~1740-line @Observable @MainActor AppState god object; depends on Core + Sparkle). On-disk model: a vault of original files + a hidden .openphoto/ (vault.json, manifest.jsonl, bin/) + a rebuildable global SQLite catalog + per-file XMP sidecars for human metadata. Heavy work is supposed to run via Task.detached(.utility); only observable state lives on the main actor. LibraryService is the Core façade (a plain Sendable class, synchronous I/O). The catalog browse path is a UNION of local instances and drive-only presence rows (Catalog/Queries.swift timelineSQL).`

// ---- schemas -------------------------------------------------------------
const COMPLEXITY_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['module', 'summary', 'findings'],
  properties: {
    module: { type: 'string' }, summary: { type: 'string', description: 'one paragraph on how this subsystem scales' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['operation', 'locations', 'time', 'space', 'trigger', 'cliff', 'severity', 'confidence', 'improvement', 'effort'],
      properties: {
        operation: { type: 'string', description: 'the operation/function analysed' },
        locations: { type: 'array', items: { type: 'string' }, description: 'exact path/File.swift:line sites' },
        time: { type: 'string', description: 'big-O time in scale vocab + dominant term' },
        space: { type: 'string', description: 'big-O space / memory held resident' },
        trigger: { type: 'string', description: 'when and how often it runs' },
        cliff: { type: 'string', description: 'library size where it bites + concrete symptom' },
        severity: { enum: ['Critical', 'High', 'Medium', 'Low'], description: 'by scaling impact' },
        confidence: { enum: ['Confirmed', 'Suspected', 'Needs verification'] },
        improvement: { type: 'string', description: 'target complexity + the approach to get there' },
        effort: { enum: ['S', 'M', 'L'] },
      },
    } },
  },
}

const DESIGN_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['module', 'summary', 'findings'],
  properties: {
    module: { type: 'string' }, summary: { type: 'string', description: 'one paragraph on this subsystem’s structural design' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['title', 'locations', 'area', 'severity', 'confidence', 'problem', 'proposedChange', 'risk', 'effort'],
      properties: {
        title: { type: 'string' },
        locations: { type: 'array', items: { type: 'string' } },
        area: { enum: ['architecture', 'coupling', 'abstraction', 'data-model', 'error-model', 'concurrency-architecture', 'api-design', 'duplication', 'testability', 'extensibility', 'dead-code'] },
        severity: { enum: ['Critical', 'High', 'Medium', 'Low'] },
        confidence: { enum: ['Confirmed', 'Suspected', 'Needs verification'] },
        problem: { type: 'string', description: 'the structural problem and its consequence' },
        proposedChange: { type: 'string', description: 'concrete target structure / refactor' },
        risk: { type: 'string', description: 'blast radius / migration risk of the change' },
        effort: { enum: ['S', 'M', 'L'] },
      },
    } },
  },
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['isReal', 'adjustedConfidence', 'note'],
  properties: {
    isReal: { type: 'boolean' },
    adjustedSeverity: { enum: ['Critical', 'High', 'Medium', 'Low'] },
    adjustedConfidence: { enum: ['Confirmed', 'Suspected', 'Needs verification'] },
    note: { type: 'string' },
  },
}

const TILE_OPTIONS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['options', 'recommendation'],
  properties: {
    options: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['name', 'mechanism', 'expectedEffect', 'apiFit', 'preservesFeatures', 'effort', 'risk'],
      properties: {
        name: { type: 'string' },
        mechanism: { type: 'string', description: 'how it works technically' },
        expectedEffect: { type: 'string', description: 'which cost it removes at small tile sizes + rough magnitude' },
        apiFit: { type: 'string', description: 'SwiftUI / AppKit / Metal fit and integration cost' },
        preservesFeatures: { type: 'string', description: 'compatibility with selection ring, hover, drag, context menu, badges, async fill-in, live update' },
        effort: { enum: ['S', 'M', 'L', 'XL'] },
        risk: { type: 'string' },
      },
    } },
    recommendation: { type: 'string', description: 'which option(s) to do, in what order, and why' },
  },
}

// ---- subsystem work-list -------------------------------------------------
const CLUSTERS = [
  { key: 'catalog-query', label: 'Catalog, queries & search', files: [
      'Sources/OpenPhotoCore/Catalog/Catalog.swift','Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift','Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift','Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift','Sources/OpenPhotoCore/Catalog/Catalog+FinderTags.swift','Sources/OpenPhotoCore/Catalog/Catalog+FolderOps.swift','Sources/OpenPhotoCore/Catalog/Catalog+Geocode.swift','Sources/OpenPhotoCore/Catalog/Catalog+PHash.swift','Sources/OpenPhotoCore/Catalog/PendingDeletion.swift','Sources/OpenPhotoCore/Catalog/Records.swift','Sources/OpenPhotoCore/Catalog/Queries.swift','Sources/OpenPhotoCore/Search/Catalog+Search.swift','Sources/OpenPhotoCore/Search/SearchRanker.swift','Sources/OpenPhotoCore/Search/SemanticIndex.swift','Sources/OpenPhotoCore/Search/DatePreset.swift'],
    focus: 'THE data-scaling core. Schema design & normalization (assets/instances/vault_presence). INDEX COVERAGE vs query predicates — read every CREATE INDEX in the migrations and match against the WHERE/JOIN/ORDER BY of every query. The browse UNION (timelineSQL) uses a correlated `vp.rowid = (SELECT MIN(rowid) FROM vault_presence v2 WHERE v2.hash = vp.hash)` per drive-only row and a NOT EXISTS — analyse whether this is O(N^2)/full-scan without the right index. GLOB folder queries (items(inDir:recursive), folderCounts) cannot use a B-tree index → full table scan; quantify. timelineItems materialises ALL rows + sorts in memory (no pagination). SemanticIndex holds all E embeddings in RAM — compute the footprint at 100k and 1M. knownSizeDateKeys/assetHashes build whole-table Sets. SearchRanker per-query cost & numeric stability.' },
  { key: 'vault-format-io', label: 'Vault format, IO, sidecars', files: [
      'Sources/OpenPhotoCore/Vault/BinStore.swift','Sources/OpenPhotoCore/Vault/FileNaming.swift','Sources/OpenPhotoCore/Vault/Manifest.swift','Sources/OpenPhotoCore/Vault/Vault.swift','Sources/OpenPhotoCore/Vault/VaultDescriptor.swift','Sources/OpenPhotoCore/Vault/VaultReorganizer.swift','Sources/OpenPhotoCore/IO/AtomicFile.swift','Sources/OpenPhotoCore/IO/URL+MediaPackage.swift','Sources/OpenPhotoCore/Hashing/ContentHash.swift','Sources/OpenPhotoCore/Sidecar/FaceRegion.swift','Sources/OpenPhotoCore/Sidecar/SidecarData.swift','Sources/OpenPhotoCore/Sidecar/SidecarStore.swift','Sources/OpenPhotoCore/Sidecar/XMP.swift','Sources/OpenPhotoCore/Interop/FinderTags.swift','Sources/OpenPhotoCore/Interop/SidecarExporter.swift','Sources/OpenPhotoCore/Interop/TagMerge.swift'],
    focus: 'On-disk format design (is it good for the documented third-party / server consumer?) and the cost of mutating it. manifest.jsonl is a SINGLE file read + sorted + rewritten wholesale on every entry change → O(M) per write, and any per-file loop over it is O(M^2). Sidecar-per-file design: F+ small files; ingest/export cost is O(N) file opens. AtomicFile/ContentHash time+space. BinStore design. FileNaming collision handling complexity.' },
  { key: 'scan-index', label: 'Scan & indexing pipeline', files: [
      'Sources/OpenPhotoCore/Scanner/Scanner.swift','Sources/OpenPhotoCore/Scanner/FolderWatcher.swift','Sources/OpenPhotoCore/Presence/PresenceService.swift','Sources/OpenPhotoCore/Presence/BackupProbe.swift','Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift','Sources/OpenPhotoCore/Media/LivePhotoPairer.swift','Sources/OpenPhotoCore/Media/MediaKind.swift','Sources/OpenPhotoCore/Media/MediaMetadata.swift','Sources/OpenPhotoCore/Media/MetadataExtractor.swift'],
    focus: 'Scan is single-threaded O(files) walk; hashing O(bytes); the size+mtime fast-path needs the whole manifest as a dict in RAM (O(M) space). replaceInstances rewrites all instances wholesale. Live-photo pairing complexity (per-folder pairing — O(n) or O(n^2)?). Design: is the pipeline parallelisable; is the watcher debounced; resumability. Memory during scan.' },
  { key: 'derivation-ml', label: 'Derivation / ML pipeline', files: [
      'Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift','Sources/OpenPhotoCore/Derivation/DerivationStage.swift','Sources/OpenPhotoCore/Derivation/EmbedStage.swift','Sources/OpenPhotoCore/Derivation/FaceStage.swift','Sources/OpenPhotoCore/Derivation/GeocodeStage.swift','Sources/OpenPhotoCore/Derivation/OCRStage.swift','Sources/OpenPhotoCore/Derivation/PHashStage.swift','Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift','Sources/OpenPhotoCore/Geocode/ReverseGeocoder.swift'],
    focus: 'Stage/job-queue design (resumable, retry-capped) — assess it. Per-stage time (inference) + space (FULL-RES decode, CVPixelBuffer, MLMultiArray) per asset; the runner drains the WHOLE pending set serially. Model load/compile cost & whether it is cached vs rebuilt per call (EmbedStage). GeoNames table held in RAM (space). ReverseGeocoder lookup: linear scan over all geonames per photo (O(G) each → O(N·G)) vs a spatial index? Tokenizer build cost.' },
  { key: 'cull-faces', label: 'Cull & faces (clustering/dedup)', files: [
      'Sources/OpenPhotoCore/Cull/BurstGrouper.swift','Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift','Sources/OpenPhotoCore/Cull/FocusMeasure.swift','Sources/OpenPhotoCore/Cull/KeeperSelector.swift','Sources/OpenPhotoCore/Cull/PerceptualHash.swift','Sources/OpenPhotoCore/Faces/FaceClusterer.swift'],
    focus: 'CLUSTERING COMPLEXITY is the headline. FaceClusterer greedy single-link agglomerative: O(n^2) pairwise cosine (or worse) AND chaining (a design defect → wrong clusters). BurstGrouper, DuplicateGrouper union-find per folder: per-folder O(n^2) pHash Hamming? Quantify at large N. Design: general feature-print vs face-identity embedding; single-link vs centroid/HDBSCAN. Data structures.' },
  { key: 'import', label: 'Import engines', files: [
      'Sources/OpenPhotoCore/Import/CameraIdentity.swift','Sources/OpenPhotoCore/Import/CameraSource.swift','Sources/OpenPhotoCore/Import/ForeignVaultSource.swift','Sources/OpenPhotoCore/Import/ImportEngine.swift','Sources/OpenPhotoCore/Import/ImportRegistry.swift','Sources/OpenPhotoCore/Import/ImportSource.swift','Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift','Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift','Sources/OpenPhotoCore/Import/TakeoutMetadata.swift','Sources/OpenPhotoCore/Import/TakeoutSource.swift','Sources/OpenPhotoCore/Import/VolumeSource.swift'],
    focus: 'ImportSource protocol design & consistency across camera/volume/PhotoKit/Takeout/foreign. Dedup fingerprint set build cost. Takeout JSON→media matching complexity (per-file linear scan over JSON index → O(files·json)?). Registry persistence cost (rewrite whole file per item?). Copy+hash-verify throughput; memory per item.' },
  { key: 'sync-send', label: 'Sync & send engines', files: [
      'Sources/OpenPhotoCore/Sync/BackupStatus.swift','Sources/OpenPhotoCore/Sync/CanonicalManagement.swift','Sources/OpenPhotoCore/Sync/CatalogIngest.swift','Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift','Sources/OpenPhotoCore/Sync/DeletionPropagator.swift','Sources/OpenPhotoCore/Sync/DriftReconciler.swift','Sources/OpenPhotoCore/Sync/DriftReport.swift','Sources/OpenPhotoCore/Sync/DriveKind.swift','Sources/OpenPhotoCore/Sync/DriveVolume.swift','Sources/OpenPhotoCore/Sync/PeekSource.swift','Sources/OpenPhotoCore/Sync/SyncEngine.swift','Sources/OpenPhotoCore/Sync/SyncLog.swift','Sources/OpenPhotoCore/Sync/SyncPlan.swift','Sources/OpenPhotoCore/Sync/VerifiedCopy.swift','Sources/OpenPhotoCore/Send/DeviceRegistry.swift','Sources/OpenPhotoCore/Send/LibraryService+SendSource.swift','Sources/OpenPhotoCore/Send/SendDestination.swift','Sources/OpenPhotoCore/Send/SendEngine.swift','Sources/OpenPhotoCore/Send/SendRegistry.swift','Sources/OpenPhotoCore/Send/SendReverifier.swift','Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift'],
    focus: 'Sync plan diff: is it dict-based O(S+Dst) or nested-loop O(S·Dst)? DriftReconciler bulk repair rewrites the whole manifest PER FILE (O(N·M) quadratic) — quantify. CatalogSnapshot build/parse cost. DeletionPropagator (does it do the single-rewrite correctly?). Engine design consistency (three engines, shared abstractions?). Reverify cost.' },
  { key: 'libsvc', label: 'LibraryService orchestration & selection', files: [
      'Sources/OpenPhotoCore/LibraryService.swift','Sources/OpenPhotoCore/LibraryService+DriveSource.swift','Sources/OpenPhotoCore/LibraryService+Eviction.swift','Sources/OpenPhotoCore/LibraryService+Move.swift','Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift','Sources/OpenPhotoCore/Selection/SelectionModel.swift','Sources/OpenPhotoCore/Selection/UndoAction.swift'],
    focus: 'Façade design: LibraryService is a plain Sendable class doing SYNCHRONOUS I/O on the caller (often main) actor — should it be an actor? folderTree cost (folderCounts SQL + directoriesUnder full FS walk, unioned). Eviction/move complexity. SelectionModel tap/range math (firstIndex linear scans → O(K·P)?); selection data structure (Set vs array). UndoAction memory.' },
  { key: 'appstate-arch', label: 'AppState architecture', files: [
      'Sources/OpenPhotoApp/AppState.swift','Sources/OpenPhotoApp/AppState+FolderReorg.swift','Sources/OpenPhotoApp/AppState+Undo.swift'],
    focus: 'THE central design target. Propose a concrete decomposition of the ~1740-line @MainActor god object into focused services (library/query, search, derivation runner, drives/roles, people, cull, undo). Complexity: refreshQueries rebuilds sections+flatItems+folderTree (O(N+F), full DB load + FS walk) on EVERY state change (~15 triggers) on the main actor. One @Observable invalidating all views (publishing granularity). Derivation runner drain design. Drives/role orchestration sprawl.' },
  { key: 'ui-grid-media', label: 'Grid, viewer & media UI', files: [
      'Sources/OpenPhotoApp/Tiles/MediaTile.swift','Sources/OpenPhotoApp/Tiles/ThumbnailImage.swift','Sources/OpenPhotoApp/Viewer/PlayerView.swift','Sources/OpenPhotoApp/Viewer/ViewerView.swift','Sources/OpenPhotoApp/Timeline/TimelineView.swift','Sources/OpenPhotoApp/Peek/PeekView.swift','Sources/OpenPhotoApp/Folders/FolderGridView.swift','Sources/OpenPhotoApp/Folders/FoldersView.swift','Sources/OpenPhotoApp/Folders/FolderTreeView.swift','Sources/OpenPhotoApp/Selection/SelectionUI.swift'],
    focus: 'Grid rendering at scale (the tile track covers the renderer redesign in depth — here assess the data path + view architecture). flatItems materialisation (all P TimelineItems as one array); LazyVGrid identity/laziness; per-render recomputation; rubber-band selection hit-test complexity over P items; viewer decode; FolderTree build cost. Note where this overlaps the tile plan and defer the renderer specifics to it.' },
  { key: 'ui-feature-views', label: 'Feature views (map, people, search, drives, devices, shell)', files: [
      'Sources/OpenPhotoApp/Map/MapView.swift','Sources/OpenPhotoApp/People/PeopleView.swift','Sources/OpenPhotoApp/Search/ProFilterBar.swift','Sources/OpenPhotoApp/Search/SearchView.swift','Sources/OpenPhotoApp/Search/SimpleFilterBar.swift','Sources/OpenPhotoApp/Search/FilterChip.swift','Sources/OpenPhotoApp/Search/DatePreset+UI.swift','Sources/OpenPhotoApp/Inspector/InspectorView.swift','Sources/OpenPhotoApp/Cleanup/CleanupView.swift','Sources/OpenPhotoApp/Drives/DrivesView.swift','Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift','Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift','Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift','Sources/OpenPhotoApp/Drives/DeletionListView.swift','Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift','Sources/OpenPhotoApp/Devices/DeviceWatcher.swift','Sources/OpenPhotoApp/Devices/ImportView.swift','Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift','Sources/OpenPhotoApp/Devices/ImportItemCell.swift','Sources/OpenPhotoApp/Settings/SettingsView.swift','Sources/OpenPhotoApp/Sidebar/SidebarView.swift','Sources/OpenPhotoApp/OpenPhotoApp.swift','Sources/OpenPhotoApp/WindowControls.swift'],
    focus: 'MapView re-clusters on every region change (O(P) per pan/zoom) + thumbnail providers. PeopleView (812 lines) renders many face cards each cropping on the fly. Search UI debounce/recompute. Drives sheets data prep. Per-view recomputation in body. View architecture / state binding consistency.' },
]

// ---- prompts -------------------------------------------------------------
function complexityPrompt(c) {
  return `You are a performance/scalability auditor doing a READ-ONLY time & space complexity audit of the OpenPhoto subsystem "${c.label}".

${PRIMER}

${SCALE}

Repository root: ${ROOT} (your working directory). Read every file below IN FULL with the Read tool; grep for callers/triggers and for CREATE INDEX / schema when a complexity claim depends on index coverage or call frequency. DO NOT MODIFY ANY FILE.

Files:
${c.files.map(f => '  - ' + f).join('\n')}

Subsystem focus:
${c.focus}

For each non-trivial operation, determine its TIME and SPACE complexity in the scale vocabulary, what triggers it and how often, and the library size at which it becomes a user-visible problem (the cliff) with the concrete symptom. REPORT operations that are super-linear, hold large or unbounded memory resident, run very frequently (e.g. per-render, per-keystroke, on every state change), or re-do expensive work that could be cached. Skip trivially O(1)/O(small) operations. Always give a concrete improvement with its TARGET complexity. Cite exact path/File.swift:line. Mark confidence honestly (Confirmed = you traced it; Suspected = depends on caller/runtime; Needs verification = couldn't confirm from code). Severity = scaling impact (Critical = crash/OOM/unusable at realistic sizes; High = serious slowdown users hit, or quadratic that bites by ~10k; Medium = wasteful/slow at large scale; Low = minor). Return the structured object.`
}

function designPrompt(c) {
  return `You are a software architect doing a READ-ONLY STRUCTURAL design review of the OpenPhoto subsystem "${c.label}". Focus on high-leverage architecture — module boundaries, the data model, abstraction quality, the concurrency architecture, API design, error model, testability, extensibility — and propose CONCRETE target structures. Go beyond line-level nits (a separate bug audit already lists those); prefer ~3-6 structural findings over many small ones. Where the subsystem is well-designed, say so plainly.

${PRIMER}

Repository root: ${ROOT} (your working directory). Read every file below IN FULL; grep for cross-module usage when judging coupling. DO NOT MODIFY ANY FILE.

Files:
${c.files.map(f => '  - ' + f).join('\n')}

Subsystem focus:
${c.focus}

For each finding: name the structural problem and its consequence (maintainability, correctness risk, blocked roadmap, coupling), cite exact path/File.swift:line, and give a concrete proposedChange (the target structure / refactor — a short sketch is fine) plus its risk (blast radius / migration cost). Severity: Critical = structural flaw causing data-integrity/correctness risk or blocking the documented roadmap (e.g. third-party/server consumer of the canonical drive); High = significant coupling/maintainability problem with broad blast radius; Medium = notable; Low = minor. Mark confidence. Return the structured object.`
}

function verifyPrompt(x) {
  const f = x.f
  const body = x.kind === 'complexity'
    ? `- Operation: ${f.operation}\n- Claimed TIME: ${f.time}\n- Claimed SPACE: ${f.space}\n- Trigger: ${f.trigger}\n- Cliff: ${f.cliff}\n- Proposed improvement: ${f.improvement}\n\nCheck the big-O against the ACTUAL loop nesting, data structures, and index coverage (read the schema/CREATE INDEX if relevant). A claim of O(n^2)/full-scan is only real if the code truly nests or the predicate truly can't use an index.`
    : `- Title: ${f.title}\n- Area: ${f.area}\n- Problem: ${f.problem}\n- Proposed change: ${f.proposedChange}\n- Risk: ${f.risk}\n\nCheck the structural claim is fair (not a misreading) and the proposed change is sound and actually better.`
  return `You are an adversarial verifier for a ${x.kind} finding (severity ${f.severity}) in OpenPhoto (macOS Swift/SwiftUI app). REFUTE it: read the cited code yourself and decide if it genuinely holds. Default isReal=false unless the code clearly confirms it; be skeptical of severity inflation.

Repository root: ${ROOT} (your working directory). Read the cited files/lines and any caller/definition/schema you need. DO NOT MODIFY ANYTHING.

- Severity: ${f.severity} | Confidence: ${f.confidence}
- Locations: ${f.locations.join(', ')}
${body}

Return: isReal; adjustedSeverity (corrected if over/under-rated, else echo); adjustedConfidence; note (1-2 sentences on what the code actually shows).`
}

// ---- run -----------------------------------------------------------------
phase('Map')
const scaleModelP = agent(
  `Read-only scale-model mapper for OpenPhoto (macOS Swift/SwiftUI photo manager). Repository root: ${ROOT} (your working directory).

${PRIMER}

Read: Package.swift; Catalog/Catalog.swift (ALL migrations + every CREATE INDEX); Catalog/Queries.swift; Search/Catalog+Search.swift; Scanner/Scanner.swift; AppState.swift (skim refreshQueries, drainDerivation, runSearch); Sync/DriftReconciler.swift; Faces/FaceClusterer.swift; Tiles/ThumbnailImage.swift; Thumbnails/ThumbnailStore.swift. Glob the Sources tree.

Produce three things as markdown prose (no preamble):
1. "Scale model" — restate the scale parameters (N, M, F, V, D, E, P, T, K, B) with what each maps to in this app, and the three reference sizes (10k / 100k / 1M).
2. "Hot-path inventory" — the ~12-15 most performance-critical operations (scan, derivation drain, refreshQueries, timeline/folder queries, search, folderTree, sync plan, drift repair, clustering, tile/thumbnail load, map clustering), each with where it lives (file:line) and what scale parameter dominates it.
3. "Index coverage" — a table of the catalog's actual indexes (from the migrations) vs the predicates of the main queries, flagging queries that have NO supporting index (full scan) or rely on correlated subqueries.
Return ONLY the markdown.`,
  { label: 'scale-model', phase: 'Map' }
)

// ---- tile-system deep dive (runs concurrently with the cluster audit) ----
const TILE_FILES = 'Sources/OpenPhotoApp/Tiles/MediaTile.swift, Sources/OpenPhotoApp/Tiles/ThumbnailImage.swift, Sources/OpenPhotoApp/Timeline/TimelineView.swift, Sources/OpenPhotoApp/Folders/FolderGridView.swift, Sources/OpenPhotoApp/Selection/SelectionUI.swift, Sources/OpenPhotoApp/People/PeopleView.swift, Sources/OpenPhotoApp/Cleanup/CleanupView.swift, Sources/OpenPhotoApp/Theme.swift, Sources/OpenPhotoCore/Thumbnails/ThumbnailStore.swift, and the gridThumbnailPixels / cell-sizing / zoom helpers (grep for them)'
phase('Tile')
const tileP = (async () => {
  const [tmap, tgpu, topts] = await Promise.all([
    agent(`READ-ONLY: trace OpenPhoto's tile/thumbnail rendering pipeline END TO END and report where time, memory, and GPU cost go AT SMALL TILE SIZES (the dense grid at minimum zoom: small ~80-120pt cells, many HUNDREDS visible at once). Repository root: ${ROOT}.

${PRIMER}

Read in full: ${TILE_FILES}. Trace: catalog → AppState.flatItems/sections → the grid (LazyVGrid in TimelineView/FolderGridView) → MediaTile → ThumbnailImage (shared NSCache, cacheKey "id@targetPixel", .task(id:) async load) → ThumbnailStore (on-disk thumbnail generation/caching) → Image/NSImage → CALayer/GPU texture. Determine, concretely, at min zoom: (1) how many SwiftUI views / Image layers / distinct GPU textures exist for the visible grid; (2) where decoding happens and at WHAT pixel size — is targetPixel matched to on-screen points × backing scale, or larger than needed for tiny tiles? how is gridThumbnailPixels chosen and quantized?; (3) NSCache behaviour — countLimit, key cardinality as zoom changes, hit/miss on zoom in/out, whether it's bounded by bytes; (4) what work happens on Space-switch / scroll / zoom change (sync decode? view rebuild?). Quantify per-tile cost and the total at, say, 400 visible tiles. Return ONLY markdown prose: "Current tile pipeline" + "Where the cost is at small sizes".`, { label: 'tile:trace', phase: 'Tile' }),
    agent(`READ-ONLY: diagnose the GPU / Core Animation / compositing cost of OpenPhoto's photo grid AT SMALL TILE SIZES, and explain the known Space-switch hitch at minimum zoom (suspected root cause: each tile becomes its own GPU texture/layer, so hundreds of tiny tiles = hundreds of textures). Repository root: ${ROOT}.

${PRIMER}

Read: ${TILE_FILES}. From the code, confirm or refute the per-image-texture diagnosis: how does a SwiftUI Image / NSImage in a LazyVGrid map to CALayers and GPU textures? Why are hundreds of small layers materially worse for the compositor (and for a macOS Space switch, which recomposites the whole window) than a few large ones? Estimate textures resident and approximate VRAM at min zoom (e.g. 400-800 tiles). Assess whether .drawingGroup()/Canvas, layer rasterization, or fewer-larger-layers would help, and any current anti-patterns (per-tile shadows/overlays/rounded-rect masks forcing offscreen passes; selection ring / badge layers multiplying layer count). Return ONLY markdown prose: a crisp diagnosis with the dominant GPU cost and confidence.`, { label: 'tile:gpu-cost', phase: 'Tile' }),
    agent(`READ-ONLY: propose concrete redesign OPTIONS to make OpenPhoto's photo grid FAR FASTER and more memory-efficient AT SMALL TILE SIZES (dense grid, hundreds of small tiles, smooth scroll + smooth macOS Space switch). Repository root: ${ROOT}.

${PRIMER}

Read: ${TILE_FILES}, and note the features each tile must keep: async thumbnail fill-in, selection ring + selected state, hover, drag-and-drop (PhotoMovePayload), context menus, keeper/badge overlays, rubber-band selection (SelectionUI), live update on edit/delete, Live-photo/video affordances. Produce 3-5 distinct options. Candidates to consider and adapt (don't just list — evaluate against THIS code): (A) SwiftUI Canvas / GraphicsContext single-layer grid that draws cached downsampled CGImages in one pass (collapses N textures → ~1); (B) AppKit NSCollectionView with cell reuse + prefetch + layer.contents = downsampled CGImage; (C) a thumbnail texture atlas; (D) downsample-on-decode discipline + size-bucketed cache keys + cost(byte)-bounded NSCache + .drawingGroup() rasterization of each tile; (E) a hybrid (Canvas/atlas for the image plane with a thin SwiftUI overlay for selection/hover/drag). For EACH option fill the schema: mechanism, expectedEffect (which cost it removes + rough magnitude), apiFit, preservesFeatures (be specific about selection/drag/context-menu/rubber-band/badges/async fill-in), effort, risk. Then a recommendation: which to do first and the sequence. Return the structured object.`, { label: 'tile:options', phase: 'Tile', schema: TILE_OPTIONS_SCHEMA }),
  ])
  const recoName = (topts && topts.recommendation) ? topts.recommendation : 'the recommended renderer redesign'
  const tverify = await agent(`READ-ONLY adversarial feasibility check. A tile-grid redesign is proposed for OpenPhoto to speed up small tiles. Recommendation: "${recoName}". Options considered: ${topts ? topts.options.map(o => o.name).join('; ') : '(none)'}. Repository root: ${ROOT}.

Read the ACTUAL tile code (${TILE_FILES}) and pressure-test the recommended approach against every feature a tile currently supports: async thumbnail fill-in and the .task(id:) cache-key swap, selection ring + selected styling, hover, drag-and-drop via PhotoMovePayload, context menus, keeper/other badges, the rubber-band marquee in SelectionUI (which needs per-tile frames/coordinate-space), and live update when an item is edited/deleted. For each, say whether the recommended renderer preserves it cleanly, makes it harder (how), or breaks it. Flag any overstated speedup. Be concrete and skeptical. Return ONLY markdown prose: "Feasibility & caveats".`, { label: 'tile:verify', phase: 'Tile' })
  const plan = await agent(`Write the "Tile System Optimization Plan" for OpenPhoto — a concrete, sequenced plan to make the photo grid far faster and lighter AT SMALL TILE SIZES. You are given four analyses; synthesise them into an actionable plan (do not just concatenate). Repository root: ${ROOT} (you may re-read tile files to ground specific code-level steps).

PIPELINE TRACE:
${tmap}

GPU COST DIAGNOSIS:
${tgpu}

REDESIGN OPTIONS (structured): ${JSON.stringify(topts)}

FEASIBILITY & CAVEATS:
${tverify}

Write markdown prose with: (1) "Bottleneck" — one tight paragraph naming the dominant cost at small tile sizes and why. (2) "Plan" — an ORDERED list of changes from quick wins (downsample/targetPixel quantization, cost-bounded cache, fewer offscreen passes) to the structural renderer change (the recommended option), each step with: the concrete code-level change (files/functions to touch), expected effect at small sizes, how it preserves tile features (selection/drag/context-menu/rubber-band/badges/async fill-in), effort (S/M/L/XL), and risk. (3) "Target" — the end-state and a rough success metric (e.g. smooth 60fps scroll + hitch-free Space switch at 600+ visible tiles, bounded VRAM). (4) "Spike first" — the single smallest experiment that would validate the structural change before committing. Return ONLY the markdown.`, { label: 'tile:plan', phase: 'Tile' })
  return { tmap, tgpu, topts, tverify, plan }
})()

phase('Audit')
log(`Auditing ${CLUSTERS.length} subsystems on two lenses (complexity + design); Critical/High claims verified adversarially.`)
const audited = await pipeline(
  CLUSTERS,
  c => parallel([
    () => agent(complexityPrompt(c), { label: `cx:${c.key}`, phase: 'Audit', schema: COMPLEXITY_SCHEMA }),
    () => agent(designPrompt(c), { label: `design:${c.key}`, phase: 'Audit', schema: DESIGN_SCHEMA }),
  ]).then(([cx, dz]) => ({
    module: c.label, key: c.key,
    cxSummary: cx ? cx.summary : '', designSummary: dz ? dz.summary : '',
    complexity: (cx ? cx.findings : []).map(f => ({ ...f, verdict: null })),
    design: (dz ? dz.findings : []).map(f => ({ ...f, verdict: null })),
  })),
  (audit, c) => {
    if (!audit) return null
    const cand = [
      ...audit.complexity.map((f, i) => ({ kind: 'complexity', i, f })),
      ...audit.design.map((f, i) => ({ kind: 'design', i, f })),
    ].filter(x => x.f.severity === 'Critical' || x.f.severity === 'High')
    if (!cand.length) return audit
    return parallel(cand.map(x => () =>
      agent(verifyPrompt(x), { label: `verify:${c.key}:${x.kind}#${x.i + 1}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then(v => ({ ...x, v }))
    )).then(rs => {
      for (const r of rs) {
        if (r && r.v) (r.kind === 'complexity' ? audit.complexity : audit.design)[r.i].verdict = r.v
      }
      return audit
    })
  }
)

const modules = audited.filter(Boolean)
const complexityFindings = modules.flatMap(m => m.complexity.map(f => ({ ...f, module: m.module, moduleKey: m.key })))
const designFindings = modules.flatMap(m => m.design.map(f => ({ ...f, module: m.module, moduleKey: m.key })))

phase('Synthesize')
const cxCompact = complexityFindings.map(f =>
  `[${f.severity}] ${f.module}: ${f.operation} — time ${f.time}; space ${f.space}; cliff ${f.cliff}${f.verdict ? ` (verified isReal=${f.verdict.isReal})` : ''}`).join('\n')
const dzCompact = designFindings.map(f =>
  `[${f.severity}/${f.area}] ${f.module}: ${f.title}${f.verdict ? ` (verified isReal=${f.verdict.isReal})` : ''}`).join('\n')

const scalingNarrativeP = agent(
  `You are writing the scaling narrative for an OpenPhoto performance audit (macOS photo manager). Below are the complexity findings. Write markdown prose (no preamble): "How OpenPhoto scales" — walk through what the user experiences at 10k, 100k, and 1M photos, naming the specific operations that degrade first (cite the operation names), where the hard cliffs are (OOM / multi-second hangs / quadratic blowups), and the 4-6 changes that would move the ceiling the most. Be concrete and quantitative where the findings allow.

Complexity findings:
${cxCompact}`, { label: 'scaling-narrative', phase: 'Synthesize' })

const targetArchP = agent(
  `You are writing the target-architecture section for an OpenPhoto design audit (macOS Swift/SwiftUI photo manager; today: a thin Core library + a ~1740-line @MainActor AppState god object + LibraryService façade doing synchronous I/O). Below are the structural design findings. Write markdown prose (no preamble): "Target architecture & refactor roadmap" — propose the end-state structure (how AppState should decompose into services; where the actor/async boundary for Catalog+IO should sit; the error model; abstraction boundaries for import/sync/send; data-model improvements) and a PRIORITISED, SEQUENCED roadmap (what to do first for the most leverage and least risk, what enables what). Tie each step back to the finding areas it resolves.

Design findings:
${dzCompact}`, { label: 'target-architecture', phase: 'Synthesize' })

const [scaleModel, tile, scalingNarrative, targetArch] = await Promise.all([scaleModelP, tileP, scalingNarrativeP, targetArchP])

return { scaleModel, tile, scalingNarrative, targetArch, modules, complexityFindings, designFindings }
