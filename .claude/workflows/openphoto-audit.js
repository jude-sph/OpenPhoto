export const meta = {
  name: 'openphoto-audit',
  description: 'Read-only dual-lens multi-agent audit of OpenPhoto (macOS photo app) → structured findings for CODE_AUDIT.md',
  phases: [
    { title: 'Map', detail: 'architecture overview from entry points + data flows' },
    { title: 'Audit', detail: 'two disjoint-lens auditors per subsystem → structured findings' },
    { title: 'Verify', detail: 'adversarially confirm every Critical/High finding' },
    { title: 'Synthesize', detail: 'systemic themes + completeness critic' },
  ],
}

const ROOT = '/Users/jude/Documents/projects/OpenPhoto'

// ---- schemas -------------------------------------------------------------
const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['module', 'summary', 'findings'],
  properties: {
    module: { type: 'string' },
    summary: { type: 'string', description: 'one-paragraph plain-language read on this subsystem' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'severity', 'confidence', 'category', 'locations', 'problem', 'suggestedFix', 'effort'],
        properties: {
          title: { type: 'string', description: 'short imperative title' },
          severity: { enum: ['Critical', 'High', 'Medium', 'Low'] },
          confidence: { enum: ['Confirmed', 'Suspected', 'Needs verification'] },
          category: { enum: ['correctness', 'concurrency', 'memory', 'SwiftUI', 'file-integrity', 'security', 'performance', 'design'] },
          locations: { type: 'array', items: { type: 'string' }, description: 'exact path/File.swift:line for every relevant site' },
          problem: { type: 'string', description: 'what is wrong and the concrete failure mode / risk' },
          suggestedFix: { type: 'string', description: 'the approach; a short code sketch is fine' },
          effort: { enum: ['S', 'M', 'L'] },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['isReal', 'adjustedConfidence', 'note'],
  properties: {
    isReal: { type: 'boolean', description: 'true only if reading the cited code confirms the defect is real' },
    adjustedSeverity: { enum: ['Critical', 'High', 'Medium', 'Low'], description: 'corrected severity if over/under-rated' },
    adjustedConfidence: { enum: ['Confirmed', 'Suspected', 'Needs verification'] },
    note: { type: 'string', description: 'one or two sentences: what the code actually shows; why confirmed or refuted' },
  },
}

// ---- subsystem work-list -------------------------------------------------
const CLUSTERS = [
  { key: 'catalog', label: 'Catalog & schema', files: [
      'Sources/OpenPhotoCore/Catalog/Catalog.swift', 'Sources/OpenPhotoCore/Catalog/Catalog+Derivation.swift',
      'Sources/OpenPhotoCore/Catalog/Catalog+Embeddings.swift', 'Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift',
      'Sources/OpenPhotoCore/Catalog/Catalog+FinderTags.swift', 'Sources/OpenPhotoCore/Catalog/Catalog+FolderOps.swift',
      'Sources/OpenPhotoCore/Catalog/Catalog+Geocode.swift', 'Sources/OpenPhotoCore/Catalog/Catalog+PHash.swift',
      'Sources/OpenPhotoCore/Catalog/PendingDeletion.swift', 'Sources/OpenPhotoCore/Catalog/Records.swift'],
    focus: 'GRDB SQLite data layer. Schema migrations v1..v12 (must be append-only, idempotent, never lose data). Transaction boundaries (write blocks atomic?). String-interpolated SQL vs bound args (injection / breakage on quotes). Orphan garbage-collection correctness (which per-hash tables get GC’d on vault purge — are any, e.g. people, missed, leaving orphans or deleting live rows?). Float16/blob encode-decode. Records Codable column mapping. Int overflow on takenAtMs/size.' },
  { key: 'queries-search', label: 'Queries & Search', files: [
      'Sources/OpenPhotoCore/Catalog/Queries.swift', 'Sources/OpenPhotoCore/Search/Catalog+Search.swift',
      'Sources/OpenPhotoCore/Search/DatePreset.swift', 'Sources/OpenPhotoCore/Search/SearchRanker.swift',
      'Sources/OpenPhotoCore/Search/SemanticIndex.swift'],
    focus: 'Browse/timeline SQL (local UNION drive-only), GLOB folder matching, FTS5 OCR search, semantic (CLIP) ranking. Look for: SQL that breaks on special chars in dirPath, GLOB/LIKE escaping, N+1 query loops, full-table scans, the dedup-by-MIN(rowid) drive logic, ranker numeric stability (NaN/zero-vector cosine), SemanticIndex memory footprint of all embeddings in RAM.' },
  { key: 'vault-io', label: 'Vault, IO, Hashing', files: [
      'Sources/OpenPhotoCore/Vault/BinStore.swift', 'Sources/OpenPhotoCore/Vault/FileNaming.swift',
      'Sources/OpenPhotoCore/Vault/Manifest.swift', 'Sources/OpenPhotoCore/Vault/Vault.swift',
      'Sources/OpenPhotoCore/Vault/VaultDescriptor.swift', 'Sources/OpenPhotoCore/Vault/VaultReorganizer.swift',
      'Sources/OpenPhotoCore/IO/AtomicFile.swift', 'Sources/OpenPhotoCore/IO/URL+MediaPackage.swift',
      'Sources/OpenPhotoCore/Hashing/ContentHash.swift'],
    focus: 'THE FILE-SOVEREIGNTY CORE. Hard invariants: originals never modified/moved without explicit action; all writes atomic (temp→fsync→rename); all copies hash-verified; deletion = move to bin, never hard-delete. Audit AtomicFile for true durability (is fsync actually called before rename? parent dir fsync? crash-mid-write leaves temp turds?). ContentHash streaming + autoreleasepool. BinStore name collisions / overwrite-on-restore. Manifest write atomicity + parse robustness. VaultReorganizer move safety.' },
  { key: 'scanner-media', label: 'Scanner, Presence, Media', files: [
      'Sources/OpenPhotoCore/Scanner/Scanner.swift', 'Sources/OpenPhotoCore/Scanner/FolderWatcher.swift',
      'Sources/OpenPhotoCore/Presence/PresenceService.swift', 'Sources/OpenPhotoCore/Presence/BackupProbe.swift',
      'Sources/OpenPhotoCore/Media/EmbeddedMetadata.swift', 'Sources/OpenPhotoCore/Media/LivePhotoPairer.swift',
      'Sources/OpenPhotoCore/Media/MediaKind.swift', 'Sources/OpenPhotoCore/Media/MediaMetadata.swift',
      'Sources/OpenPhotoCore/Media/MetadataExtractor.swift'],
    focus: 'Indexing pipeline — the subsystem that OOM’d to 41GB. Per-file loop memory discipline (autoreleasepool around ImageIO CGImageSource, FileHandle, AVURLAsset). extractVideo async AVAsset path is reportedly NOT pooled — verify and flag. Force-unwrapped fm.enumerator()!. Manifest fast-path correctness (size+mtime skip can miss edits). FolderWatcher FSEvents debounce / teardown / retain. Live-photo pairing edge cases. Single-threaded scan = perf finding.' },
  { key: 'import', label: 'Import (foreign / PhotoKit / Takeout / camera)', files: [
      'Sources/OpenPhotoCore/Import/CameraIdentity.swift', 'Sources/OpenPhotoCore/Import/CameraSource.swift',
      'Sources/OpenPhotoCore/Import/ForeignVaultSource.swift', 'Sources/OpenPhotoCore/Import/ImportEngine.swift',
      'Sources/OpenPhotoCore/Import/ImportRegistry.swift', 'Sources/OpenPhotoCore/Import/ImportSource.swift',
      'Sources/OpenPhotoCore/Import/PhotosLibrarySource.swift', 'Sources/OpenPhotoCore/Import/TakeoutJSONMatcher.swift',
      'Sources/OpenPhotoCore/Import/TakeoutMetadata.swift', 'Sources/OpenPhotoCore/Import/TakeoutSource.swift',
      'Sources/OpenPhotoCore/Import/VolumeSource.swift'],
    focus: 'Copy-in flows from cameras (ImageCaptureCore), SD/USB volumes, Apple Photos (PhotoKit), Google Takeout. Verify: every copy hash-verified before source considered done; partial-copy / cancellation leaves no half-files in vault; dedup fingerprint (size|capture-second) false-positive risk (skips a real distinct photo); Takeout JSON→media matching correctness (filename truncation, (1) suffixes, edited vs original); PhotoKit async resource fetch error handling; ImportRegistry persistence races.' },
  { key: 'sync', label: 'Sync (one-way, drift, deletion propagation)', files: [
      'Sources/OpenPhotoCore/Sync/BackupStatus.swift', 'Sources/OpenPhotoCore/Sync/CanonicalManagement.swift',
      'Sources/OpenPhotoCore/Sync/CatalogIngest.swift', 'Sources/OpenPhotoCore/Sync/CatalogSnapshot.swift',
      'Sources/OpenPhotoCore/Sync/DeletionPropagator.swift', 'Sources/OpenPhotoCore/Sync/DriftReconciler.swift',
      'Sources/OpenPhotoCore/Sync/DriftReport.swift', 'Sources/OpenPhotoCore/Sync/DriveKind.swift',
      'Sources/OpenPhotoCore/Sync/DriveVolume.swift', 'Sources/OpenPhotoCore/Sync/PeekSource.swift',
      'Sources/OpenPhotoCore/Sync/SyncEngine.swift', 'Sources/OpenPhotoCore/Sync/SyncLog.swift',
      'Sources/OpenPhotoCore/Sync/SyncPlan.swift', 'Sources/OpenPhotoCore/Sync/VerifiedCopy.swift'],
    focus: 'Invariant: sync is STRICTLY ONE-WAY, drives passive, NO merge logic. Audit for any accidental two-way/merge behavior; deletion propagation that could delete the wrong side or a still-referenced file; VerifiedCopy hash-verify-before-commit; drift reconciliation that resolves by overwriting user data; snapshot read/parse robustness; partial-sync resumability; mid-sync drive yank handling.' },
  { key: 'send', label: 'Send (device/volume copy-out)', files: [
      'Sources/OpenPhotoCore/Send/DeviceRegistry.swift', 'Sources/OpenPhotoCore/Send/LibraryService+SendSource.swift',
      'Sources/OpenPhotoCore/Send/SendDestination.swift', 'Sources/OpenPhotoCore/Send/SendEngine.swift',
      'Sources/OpenPhotoCore/Send/SendRegistry.swift', 'Sources/OpenPhotoCore/Send/SendReverifier.swift',
      'Sources/OpenPhotoCore/Send/VolumeCopyDestination.swift'],
    focus: 'Copy-OUT to SD/USB volumes + AirDrop. Verify hash-verify after copy, no overwrite of existing destination files without intent, registry persistence/races, reverify correctness, free-space checks before copy, cancellation cleanup.' },
  { key: 'derivation', label: 'Derivation / ML pipeline', files: [
      'Sources/OpenPhotoCore/Derivation/CLIPTokenizer.swift', 'Sources/OpenPhotoCore/Derivation/DerivationStage.swift',
      'Sources/OpenPhotoCore/Derivation/EmbedStage.swift', 'Sources/OpenPhotoCore/Derivation/FaceStage.swift',
      'Sources/OpenPhotoCore/Derivation/GeocodeStage.swift', 'Sources/OpenPhotoCore/Derivation/OCRStage.swift',
      'Sources/OpenPhotoCore/Derivation/PHashStage.swift', 'Sources/OpenPhotoCore/Geocode/GeoNamesLoader.swift',
      'Sources/OpenPhotoCore/Geocode/ReverseGeocoder.swift'],
    focus: 'On-device Core ML / Vision pipeline run on Task.detached(.utility). Audit: per-image memory discipline (CGImage/CVPixelBuffer/MLMultiArray release, autoreleasepool); Core ML model load cost / repeated reload; not memory-pressure-aware (the 42k-asset analysis run); tokenizer buffer bounds / index errors; Vision request error handling; thread-safety of shared model handles; GeoNames loader holding a huge table in RAM.' },
  { key: 'cull-faces', label: 'Cull & Faces (clustering/dedup)', files: [
      'Sources/OpenPhotoCore/Cull/BurstGrouper.swift', 'Sources/OpenPhotoCore/Cull/DuplicateGrouper.swift',
      'Sources/OpenPhotoCore/Cull/FocusMeasure.swift', 'Sources/OpenPhotoCore/Cull/KeeperSelector.swift',
      'Sources/OpenPhotoCore/Cull/PerceptualHash.swift', 'Sources/OpenPhotoCore/Faces/FaceClusterer.swift'],
    focus: 'KNOWN BUG: FaceClusterer is greedy single-link agglomerative (join if ANY member within threshold) → chaining → a 1700-photo mega-cluster of different people; also uses a general image feature-print, not a face-identity embedding. BurstGrouper chains consecutively too. Audit clustering correctness/complexity (O(n²)+), threshold logic, KeeperSelector force-unwrap max(by:)!, union-find correctness, Hamming-distance dedup boundary, FocusMeasure on huge images.' },
  { key: 'library-sidecar', label: 'LibraryService, Sidecar, Interop, Selection', files: [
      'Sources/OpenPhotoCore/LibraryService.swift', 'Sources/OpenPhotoCore/LibraryService+DriveSource.swift',
      'Sources/OpenPhotoCore/LibraryService+Eviction.swift', 'Sources/OpenPhotoCore/LibraryService+Move.swift',
      'Sources/OpenPhotoCore/Sidecar/FaceRegion.swift', 'Sources/OpenPhotoCore/Sidecar/SidecarData.swift',
      'Sources/OpenPhotoCore/Sidecar/SidecarStore.swift', 'Sources/OpenPhotoCore/Sidecar/XMP.swift',
      'Sources/OpenPhotoCore/Interop/FinderTags.swift', 'Sources/OpenPhotoCore/Interop/SidecarExporter.swift',
      'Sources/OpenPhotoCore/Interop/TagMerge.swift', 'Sources/OpenPhotoCore/Selection/PhotoMovePayload.swift',
      'Sources/OpenPhotoCore/Selection/SelectionModel.swift', 'Sources/OpenPhotoCore/Selection/UndoAction.swift'],
    focus: 'Orchestration + human-metadata I/O. XMP sidecar write atomicity & round-trip fidelity (special chars, faces regions, ratings); sidecar/catalog consistency on failure; folder move/rename safety (the “root can’t be moved / no folder into its own descendant” guard — verify it exists and is correct); eviction logic deleting reachable files; SelectionModel range/tap index math; UndoAction inverse correctness; FinderTags xattr handling.' },
  { key: 'appstate-core', label: 'AppState (god object)', files: ['Sources/OpenPhotoApp/AppState.swift'],
    focus: 'The @Observable @MainActor god object (~1740 lines): library, queries, watchers, derivation, drives, cull, undo. Audit HARD for: heavy work on @MainActor (DB reads, file I/O, image work blocking UI); Task lifecycle & cancellation (derivationTask, watchers — leaks, double-starts, not cancelled on closeLibrary); openLibrary/closeLibrary re-entrancy and complete state reset (cross-library bleed); shared mutable state captured by detached tasks (data races, Sendable); force unwraps (state.library!); try? that swallows load failures hiding empty UI; retain cycles in closures/NotificationCenter. Also call out god-object design.' },
  { key: 'appstate-ext', label: 'AppState extensions (folder reorg, undo)', files: [
      'Sources/OpenPhotoApp/AppState+FolderReorg.swift', 'Sources/OpenPhotoApp/AppState+Undo.swift'],
    focus: 'Folder reorganization (move/rename/new-folder) and undo. Verify: no move into own descendant; root folder immovable; reorg updates catalog + moves files atomically with rollback on partial failure; undo restores exact prior state; error surfacing vs try? swallow; concurrency with in-flight scan.' },
  { key: 'media-ui', label: 'Media UI (tiles, viewer, timeline, peek)', files: [
      'Sources/OpenPhotoApp/Tiles/MediaTile.swift', 'Sources/OpenPhotoApp/Tiles/ThumbnailImage.swift',
      'Sources/OpenPhotoApp/Viewer/PlayerView.swift', 'Sources/OpenPhotoApp/Viewer/ViewerView.swift',
      'Sources/OpenPhotoApp/Timeline/TimelineView.swift', 'Sources/OpenPhotoApp/Peek/PeekView.swift'],
    focus: 'The memory- and perf-critical UI. ThumbnailImage: shared NSCache bounds, view-reuse stale-image (.task(id:) key guarding), full-res vs downsampled decode, decode off main thread. ViewerView/PlayerView: AVPlayer teardown (lingering/doubled audio fixed — verify no residual leak), full-image load on main thread. TimelineView: LazyVGrid stable identity, per-tile GPU texture blowup (known dense-grid lag), recomputation in body. Side effects in body/onAppear.' },
  { key: 'folders-map-people', label: 'Folders, Map, People UI', files: [
      'Sources/OpenPhotoApp/Folders/FolderGridView.swift', 'Sources/OpenPhotoApp/Folders/FoldersView.swift',
      'Sources/OpenPhotoApp/Folders/FolderTreeView.swift', 'Sources/OpenPhotoApp/Map/MapView.swift',
      'Sources/OpenPhotoApp/People/PeopleView.swift'],
    focus: 'FolderGridView reload() try?-swallow + videoOnly filter (count vs grid mismatch class of bug). FolderTreeView drag/drop hit-testing (contentShape+dropDestination swallowing Button). MapView clustering rep selection + thumbnail provider (shared/blank pin bug class), MKMapView update cost. PeopleView (812 lines): large list identity/laziness, face thumbnail loading on main thread, cover-face logic, recomputation.' },
  { key: 'search-inspector-cleanup', label: 'Search UI, Inspector, Cleanup, Selection UI', files: [
      'Sources/OpenPhotoApp/Search/DatePreset+UI.swift', 'Sources/OpenPhotoApp/Search/FilterChip.swift',
      'Sources/OpenPhotoApp/Search/ProFilterBar.swift', 'Sources/OpenPhotoApp/Search/SearchView.swift',
      'Sources/OpenPhotoApp/Search/SimpleFilterBar.swift', 'Sources/OpenPhotoApp/Inspector/InspectorView.swift',
      'Sources/OpenPhotoApp/Cleanup/CleanupView.swift', 'Sources/OpenPhotoApp/Selection/SelectionUI.swift'],
    focus: 'Search debounce / query-on-every-keystroke blocking main thread; filter state correctness. InspectorView (454 lines) human-metadata editing → sidecar write path, debounce, lost edits on fast switch, force unwraps. CleanupView seedSelection on signature change, delete flow. SelectionUI rubber-band index math.' },
  { key: 'drives-devices-ui', label: 'Drives & Devices UI', files: [
      'Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift', 'Sources/OpenPhotoApp/Drives/DeletionListView.swift',
      'Sources/OpenPhotoApp/Drives/DeletionReviewSheet.swift', 'Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift',
      'Sources/OpenPhotoApp/Drives/DrivesView.swift', 'Sources/OpenPhotoApp/Drives/SyncPlanSheet.swift',
      'Sources/OpenPhotoApp/Devices/DeviceWatcher.swift', 'Sources/OpenPhotoApp/Devices/FreeUpPhoneView.swift',
      'Sources/OpenPhotoApp/Devices/ImportItemCell.swift', 'Sources/OpenPhotoApp/Devices/ImportView.swift'],
    focus: 'DeviceWatcher ICDeviceBrowser/NotificationCenter start/stop balance, retain, callbacks on background thread mutating @MainActor state. Destructive-action sheets (deletion review, drift, free-up-phone) — confirm guards before irreversible copy/delete, correct counts shown, async action cancellation. ImportView large-grid performance.' },
  { key: 'shell', label: 'App shell (entry, window, sidebar, settings, send UI, bin)', files: [
      'Sources/OpenPhotoApp/OpenPhotoApp.swift', 'Sources/OpenPhotoApp/WindowControls.swift',
      'Sources/OpenPhotoApp/Sidebar/SidebarView.swift', 'Sources/OpenPhotoApp/Settings/SettingsView.swift',
      'Sources/OpenPhotoApp/Welcome/WelcomeView.swift', 'Sources/OpenPhotoApp/Theme.swift',
      'Sources/OpenPhotoApp/Send/AirDropDestination.swift', 'Sources/OpenPhotoApp/Send/SendSheet.swift',
      'Sources/OpenPhotoApp/Bin/BinView.swift'],
    focus: 'App entry / Sparkle updater wiring / window chrome / NSOpenPanel root picking / security-scoped access to the chosen root (is start/stopAccessingSecurityScopedResource + bookmark persistence correct, or does access silently break after relaunch?). Settings change-root flow. AirDrop via NSSharingService on main thread. Bin restore correctness.' },
]

const LENSES = {
  A: { name: 'Correctness & Safety',
       checklist: `- Correctness/crashes: force unwraps (!), try!, as!, unchecked subscript/first/last, off-by-one/boundary, swallowed errors (try?, catch {} hiding failures, missing user-facing error state), inverted conditions, wrong defaults, empty/nil/huge-input edge cases.
- Concurrency: main-thread blocking (file I/O, image decode, ML, heavy loops on @MainActor/main queue), data races / unsynchronised shared mutable state, Sendable violations, actor-isolation mistakes, Task lifecycle & cancellation, @unchecked Sendable, silenced isolation warnings.
- Memory/resources: retain cycles (closures capturing self strongly, strong delegates, Timer/NotificationCenter/Combine not torn down), unbounded caches/leaks, full-resolution images loaded instead of downsampled, file handles/streams not closed, missing autoreleasepool in per-file/per-image loops.
- macOS / file integrity & data loss: security-scoped bookmarks created+persisted+start/stop-accessed correctly; atomic writes & crash-mid-write/corruption/data-loss risk; migrations/backups; copies hash-verified before the source is trusted.` },
  B: { name: 'Structure & Experience',
       checklist: `- SwiftUI: wrong property wrapper (@State/@StateObject/@ObservedObject/@Bindable/@Environment), objects recreated each render, @Observable vs ObservableObject misuse, view-identity bugs, side effects in body/onAppear, excessive recomputation, lists lacking stable identity or laziness for large collections.
- Performance/scale: O(n^2)+ over large collections, sync work that should be async, missing pagination/laziness, redundant re-decoding, work repeated per-render.
- Security & privacy: Keychain/UserDefaults misuse, sensitive data in logs, SQL/path injection, unvalidated external input (Takeout JSON, drive manifests).
- Design/maintainability: god objects, tight coupling, leaky abstractions, duplicated logic, inconsistent error types, dead code, stale TODO/FIXME, missing tests around risky areas.` },
}

// ---- prompts -------------------------------------------------------------
function auditPrompt(c, lensKey) {
  const lens = LENSES[lensKey]
  return `You are a meticulous Swift / macOS code auditor doing a READ-ONLY audit of the OpenPhoto subsystem "${c.label}". Your assigned lens is "${lens.name}". Report ONLY findings in your lens's defect classes (below); a separate auditor covers the other classes, so do not duplicate their territory.

OpenPhoto is a native macOS photo manager (Swift 6 strict concurrency, SwiftUI, SwiftPM). It keeps the photo library as plain files on disk (file sovereignty) and layers an index/viewer/importer/sync over them. Core library target = OpenPhotoCore; SwiftUI app target = OpenPhotoApp. Hard invariants the code must uphold: (1) originals never modified/moved without explicit user action; (2) human metadata -> XMP sidecars, machine-derived data -> rebuildable catalog only; (3) nothing hard-deletes (deletion = move to bin); (4) all writes atomic (temp -> fsync -> rename), all copies hash-verified; (5) sync is strictly one-way, drives passive, no merge logic.

Repository root: ${ROOT} (this is your working directory). Read every file below IN FULL with the Read tool before judging it; grep/glob for cross-references when a claim depends on a caller or definition elsewhere. DO NOT MODIFY ANY FILE — the report is the only deliverable.

Files to audit:
${c.files.map(f => '  - ' + f).join('\n')}

Subsystem-specific focus (apply through your lens):
${c.focus}

YOUR LENS — hunt only for these classes:
${lens.checklist}

Rules:
- Read the actual code before any claim. Cite exact path/File.swift:line for EVERY finding (list all relevant sites in locations[]).
- Precision over volume. Skip trivial style nits with no real impact. It is fine to return few or zero findings if the subsystem is clean on your lens.
- If a recurring pattern appears at many sites in THIS subsystem, report it ONCE with all sites in locations[], not many duplicate findings.
- Mark confidence honestly: Confirmed (read the code, definitely wrong), Suspected (likely but depends on runtime/caller you couldn't fully trace), Needs verification (couldn't confirm from the code alone).
- Severity: Critical = crash, data loss/corruption, or security hole. High = wrong behaviour users will hit, or a serious leak. Medium = edge-case bug or notable design problem. Low = minor/cosmetic/maintainability.

Return the structured object: module name ("${c.label}"), a one-paragraph summary of the subsystem's health on your lens, and the findings array.`
}

function verifyPrompt(f) {
  return `You are an adversarial verifier. Another auditor flagged a ${f.severity} issue in OpenPhoto (macOS Swift/SwiftUI app). Your job is to REFUTE it: read the cited code yourself and decide whether the defect is actually real. Default to isReal=false unless the code clearly confirms it. Be skeptical of severity inflation.

Repository root: ${ROOT} (your working directory). Read the cited files/lines (and any caller/definition you need) with the Read tool. DO NOT MODIFY ANYTHING.

Claimed finding:
- Title: ${f.title}
- Severity: ${f.severity} | Category: ${f.category} | Confidence: ${f.confidence}
- Locations: ${f.locations.join(', ')}
- Problem: ${f.problem}
- Suggested fix: ${f.suggestedFix}

Decide:
- isReal: true only if the cited code genuinely exhibits the defect and the failure mode is plausible. If the code actually guards against it, or the claim misreads the code, or it depends on a condition that cannot occur, set false.
- adjustedSeverity: if real but over/under-rated, give the correct severity; otherwise echo the original.
- adjustedConfidence: Confirmed if you verified it in the code; Suspected if real-but-runtime-dependent; Needs verification if you still cannot tell.
- note: 1-2 sentences stating what the code actually shows.`
}

// ---- run -----------------------------------------------------------------
phase('Map')
const archPromise = agent(
  `Read-only architecture mapper for OpenPhoto, a native macOS photo manager (Swift 6 / SwiftUI / SwiftPM). Repository root: ${ROOT} (your working directory).

Read these to ground yourself, then describe the system: Package.swift; Sources/OpenPhotoApp/OpenPhotoApp.swift; Sources/OpenPhotoApp/AppState.swift (skim — it is the central @Observable @MainActor state object); Sources/OpenPhotoCore/LibraryService.swift; Sources/OpenPhotoCore/Catalog/Catalog.swift; Sources/OpenPhotoCore/Scanner/Scanner.swift; Sources/OpenPhotoCore/Vault/Vault.swift; Sources/OpenPhotoCore/Derivation/DerivationStage.swift; Sources/OpenPhotoCore/Sync/SyncEngine.swift. Glob the Sources tree to see the full module layout.

Write a tight "Architecture overview" (4-6 paragraphs, markdown prose, no preamble) covering: the two targets and their dependency direction; the on-disk model (vault of original files + rebuildable SQLite catalog + XMP sidecars) and the five hard invariants it enforces; the main data flows — (a) indexing/scan, (b) the on-device ML derivation pipeline and where its background work runs, (c) how the SwiftUI UI gets data via AppState, (d) import/sync/send flows; where heavy/background work is supposed to run vs the main actor; and the principal risk areas a reader should watch. Be concrete and cite a few key files inline. Return ONLY the markdown prose.`,
  { label: 'architecture', phase: 'Map' }
)

phase('Audit')
log(`Dual-lens auditing ${CLUSTERS.length} subsystems (2 auditors each); Critical/High findings verified adversarially as each module lands.`)
const audited = await pipeline(
  CLUSTERS,
  c => parallel([
    () => agent(auditPrompt(c, 'A'), { label: `audit:${c.key}:safety`, phase: 'Audit', schema: FINDING_SCHEMA }),
    () => agent(auditPrompt(c, 'B'), { label: `audit:${c.key}:design`, phase: 'Audit', schema: FINDING_SCHEMA }),
  ]).then(rs => {
    const ok = rs.filter(Boolean)
    return {
      module: c.label, key: c.key,
      summary: ok.map(r => r.summary).join(' '),
      findings: ok.flatMap(r => r.findings),
    }
  }),
  (audit, c) => {
    if (!audit) return null
    const idx = audit.findings.map((f, i) => ({ f, i })).filter(x => x.f.severity === 'Critical' || x.f.severity === 'High')
    if (idx.length === 0) return { ...audit, findings: audit.findings.map(f => ({ ...f, verdict: null })) }
    return parallel(idx.map(x => () =>
      agent(verifyPrompt(x.f), { label: `verify:${c.key}#${x.i + 1}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then(v => ({ at: x.i, v }))
    )).then(verdicts => {
      const byIndex = {}
      for (const r of verdicts) if (r) byIndex[r.at] = r.v
      return { ...audit, findings: audit.findings.map((f, i) => ({ ...f, verdict: byIndex[i] ?? null })) }
    })
  }
)

const modules = audited.filter(Boolean)
const allFindings = modules.flatMap(m => m.findings.map(f => ({ ...f, module: m.module, moduleKey: m.key })))

phase('Synthesize')
const compact = allFindings.map(f =>
  `[${f.severity}/${f.category}] ${f.module}: ${f.title}${f.verdict ? ` (verified isReal=${f.verdict.isReal})` : ''}`
).join('\n')

const themesP = agent(
  `You are synthesizing a code-audit report for OpenPhoto (macOS Swift/SwiftUI photo manager). Below are ${allFindings.length} findings from a dual-lens subsystem-by-subsystem audit. Identify the 3-6 SYSTEMIC patterns worth fixing structurally rather than case-by-case — the cross-cutting themes (a recurring unsafe idiom, a missing discipline, an architectural pressure) that explain many individual findings at once.

For each theme: a bold one-line name, then 2-4 sentences on the pattern, why it matters, the structural fix, and which finding areas it subsumes. Return ONLY markdown prose (start with the first theme; no heading, no preamble).

Findings:
${compact}`,
  { label: 'themes', phase: 'Synthesize' }
)

const critiqueP = agent(
  `You are a completeness critic for a READ-ONLY code audit of OpenPhoto (macOS Swift/SwiftUI photo manager). Repository root: ${ROOT} (your working directory). An audit covered every Swift file across these subsystems and produced the findings listed below.

Your job: judge COVERAGE, not individual findings. Glob the Sources tree and compare against the findings. Identify concrete gaps: (a) any source file or concern-class that looks under-audited, (b) cross-cutting behaviours that span subsystems and could fall between auditors (e.g. end-to-end delete→bin→drive-propagation, app-launch resume of an interrupted scan, security-scoped bookmark lifecycle across relaunch), (c) the 3-8 highest-value follow-up checks a human should run next. Be specific and cite files. Return ONLY markdown prose (a short bulleted list under an implicit heading; no preamble).

Findings so far:
${compact}`,
  { label: 'completeness-critic', phase: 'Synthesize' }
)

const [themes, critique, architecture] = await Promise.all([themesP, critiqueP, archPromise])

return { architecture, themes, critique, modules, allFindings }
