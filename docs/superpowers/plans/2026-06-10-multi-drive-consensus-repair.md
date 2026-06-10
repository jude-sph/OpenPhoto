# Multi-drive consensus repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify every connected durable drive at once and one-click **repair corrupt (bit-rot) + missing files** from any connected verified-good copy — the canonical authoritative, even repairing the canonical from a backup.

**Architecture:** One new Core primitive — `DriftReconciler.repairCorrupt` (bin-then-replace: stage+verify a good copy to a temp, quarantine the rotten original to the drive's bin, atomically place the verified file, re-record size/mtime) — reusing `VerifiedCopy` + `BinStore` unchanged except a new `BinStore.Origin.repaired` case. App adds a cross-drive sweep (`AppState.verifyAllConnected`) + repair actions + a combined `ConsensusRepairSheet`, and the existing per-drive `DriftReviewSheet` gains the corrupt Repair button.

**Tech Stack:** Swift 6 / SwiftUI / SwiftPM (Command Line Tools, no Xcode), GRDB, Swift Testing. Branch `multi-drive-consensus-repair` (off `main`).

---

## Hard rules for every task

- **Generated mock media only.** NEVER `~/Pictures`/personal folders. Core tests use temp `TestDirs` + temp vaults (`Vault.openOrCreate`) + raw `Data`/`Manifest.write` fixtures.
- **0 compiler warnings:** `swift build 2>&1 | grep -i warning` empty.
- **Do NOT modify** `VerifiedCopy`, the `SyncEngine` copy/verify spine, `Manifest`, or the send destinations. This composes them.
- **Format discipline:** the `BinStore.Origin.repaired` addition updates `docs/format/vault-format-v1.md` §8 in T4 (same slice).
- **Safe ordering is the point:** `repairCorrupt` must NEVER bin the rotten file until a verified replacement is staged — a rotten source aborts with the slot untouched. This is pinned by a test.
- Each task commits with the exact message given, ending: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/OpenPhotoCore/Vault/BinStore.swift` | **Modify.** `Origin.repaired`; `moveToBin(…, includeSidecar:)`. | T1 |
| `Sources/OpenPhotoCore/Sync/DriftReconciler.swift` | **Modify.** `repairCorrupt(...)`. | T1 |
| `Tests/OpenPhotoCoreTests/ConsensusRepairTests.swift` | **Create.** `repairCorrupt` happy path + rotten-source safety. | T1 |
| `Sources/OpenPhotoApp/AppState.swift` | **Modify.** `verifyAllConnected`, `repairCorruptOne`, `repairAllRecoverable`. | T2 |
| `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift` | **Modify.** corrupt Repair button. | T2 |
| `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift` | **Create.** cross-drive grouped review + repair. | T3 |
| `Sources/OpenPhotoApp/Drives/DrivesView.swift` | **Modify.** "Verify All Drives" entry + sheet. | T3 |
| `docs/format/vault-format-v1.md` | **Modify.** §8 bin origins. | T4 |
| `docs/superpowers/specs/2026-06-07-openphoto-design.md` | **Modify.** §10 + changelog. | T4 |

---

## Task 1: Core — `repairCorrupt` (TDD)

**Context:** `DriftReconciler.verify` flags a `corrupt` finding when a file's re-hash differs but its size+mtime still match the manifest (silent bit-rot). `VerifiedCopy.copy(from:to:expectedHash:) -> Bool` copies to a temp, fsyncs, re-hashes, atomically renames to `to` — and **returns false (writing nothing) if `to` already exists, or on any hash mismatch**. `BinStore(vault:).moveToBin(relPath:hash:origin:)` moves a file (+ its sidecar) into `<drive>/.openphoto/bin/` and logs `bin.jsonl`. `DriftReconciler.writeManifestEntry(hash:relPath:fileURL:on:)` (private, same type) re-records an entry's size+mtime. `ContentHash.ofFile(at:) throws -> ContentHash` (`.stringValue`).

**Files:**
- Modify: `Sources/OpenPhotoCore/Vault/BinStore.swift`, `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`
- Test: `Tests/OpenPhotoCoreTests/ConsensusRepairTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/OpenPhotoCoreTests/ConsensusRepairTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func seedCorruptDrive(_ t: TestDirs) throws -> (Vault, String, String, URL) {
    // A drive whose manifest records the GOOD hash for rel, but whose on-disk bytes are ROTTEN.
    // Returns (drive, rel, goodHash, goodSourceURL).
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let rel = "Pictures/rome/IMG_1.jpg"
    let dest = drive.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let source = t.root.appendingPathComponent("good.jpg")
    try Data("the real photo bytes".utf8).write(to: source)
    let goodHash = try ContentHash.ofFile(at: source).stringValue
    try Data("ROTTEN".utf8).write(to: dest)   // on-disk bytes don't match the manifest
    try Manifest.write([ManifestEntry(hash: ContentHash(stringValue: goodHash), path: rel,
        size: 20, mtime: "2022-10-07T14:23:01.000Z")], to: drive.manifestURL)
    return (drive, rel, goodHash, source)
}

@Test func repairCorruptReplacesFromGoodCopyAndBinsTheRot() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (drive, rel, goodHash, source) = try seedCorruptDrive(t)

    try DriftReconciler().repairCorrupt(relPath: rel, expectedHash: goodHash, from: source, on: drive)

    // The slot now holds the verified-good bytes.
    #expect(try ContentHash.ofFile(at: drive.absoluteURL(forRelativePath: rel)).stringValue == goodHash)
    // The rotten original is quarantined in the drive bin with origin .repaired.
    let bin = BinStore(vault: drive)
    #expect(try bin.list().contains { $0.path == rel && $0.origin == .repaired })
    #expect(FileManager.default.fileExists(atPath: bin.binnedFileURL(relPath: rel).path))
    // The manifest still records the good hash (size/mtime re-recorded to the placed file).
    let entry = try #require(try Manifest.read(from: drive.manifestURL).first { $0.path == rel })
    #expect(entry.hash.stringValue == goodHash)
}

@Test func repairCorruptAbortsOnRottenSourceLeavingSlotIntact() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let (drive, rel, goodHash, _) = try seedCorruptDrive(t)
    let dest = drive.absoluteURL(forRelativePath: rel)
    // A "source" whose bytes do NOT hash to goodHash.
    let badSource = t.root.appendingPathComponent("bad.jpg")
    try Data("also the wrong bytes".utf8).write(to: badSource)

    #expect(throws: (any Error).self) {
        try DriftReconciler().repairCorrupt(relPath: rel, expectedHash: goodHash, from: badSource, on: drive)
    }
    // Slot untouched (still the rotten on-disk bytes) and NOTHING binned.
    #expect(try Data(contentsOf: dest) == Data("ROTTEN".utf8))
    #expect(try BinStore(vault: drive).list().isEmpty)
}

@Test func binOriginRepairedRoundTrips() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("d"), role: .canonical)
    let rel = "Pictures/a.jpg"
    let f = drive.absoluteURL(forRelativePath: rel)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: f)
    try BinStore(vault: drive).moveToBin(relPath: rel,
        hash: ContentHash(stringValue: "sha256:" + String(repeating: "a", count: 64)), origin: .repaired)
    #expect(try BinStore(vault: drive).list().first?.origin == .repaired)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter repairCorruptReplacesFromGoodCopyAndBinsTheRot --filter repairCorruptAbortsOnRottenSourceLeavingSlotIntact --filter binOriginRepairedRoundTrips 2>&1 | tail -20`
Expected: FAIL to compile — `Origin.repaired` and `repairCorrupt` don't exist.

- [ ] **Step 3: Add `Origin.repaired` + `includeSidecar`**

In `Sources/OpenPhotoCore/Vault/BinStore.swift`, extend the origin enum:

```swift
    public enum Origin: String, Codable, Sendable { case user, propagated, repaired }
```

And add an `includeSidecar` option to `moveToBin` (a repaired-out media file keeps its sidecar at the live location — the asset isn't being deleted, only its damaged bytes swapped). Change the signature + guard the sidecar block:

```swift
    public func moveToBin(relPath: String, hash: ContentHash, origin: Origin,
                          includeSidecar: Bool = true) throws {
        let fm = FileManager.default
        let src = vault.absoluteURL(forRelativePath: relPath)
        let dst = vault.binDirURL.appendingPathComponent(relPath)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
        // Sidecar travels with the file, same folder-level convention inside bin/.
        let sidecar = vault.sidecarURL(forMediaAt: src)
        if includeSidecar, fm.fileExists(atPath: sidecar.path) {
            let sidecarDst = vault.sidecarURL(forMediaAt: dst)
            try fm.createDirectory(at: sidecarDst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: sidecar, to: sidecarDst)
        }
        var items = try list()
        items.append(BinItem(hash: hash.stringValue, path: relPath,
                             deletedAt: ISO8601Millis.string(from: Date()), origin: origin))
        try writeLog(items)
    }
```

- [ ] **Step 4: Add `repairCorrupt`**

In `Sources/OpenPhotoCore/Sync/DriftReconciler.swift`, add (it can call the existing private `writeManifestEntry`):

```swift
    /// Repair a corrupt (bit-rot) file from a verified-good `source`. Bin-then-replace ordering:
    /// stage + verify a copy to a temp on the drive FIRST, so a rotten/short source throws before
    /// anything is binned; then quarantine the rotten original to the drive bin (origin .repaired,
    /// sidecar kept in place), atomically place the verified file, and re-record its size/mtime
    /// (hash unchanged). Never overwrites: the placement target is absent after binning.
    public func repairCorrupt(relPath: String, expectedHash: String, from source: URL,
                              on drive: Vault) throws {
        let fm = FileManager.default
        let dest = drive.absoluteURL(forRelativePath: relPath)
        let tmp = drive.stateDirURL.appendingPathComponent("repair-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        // 1. Stage + verify a good copy. A rotten/short source fails here — nothing is binned.
        guard VerifiedCopy.copy(from: source, to: tmp, expectedHash: expectedHash) else {
            throw DriftError.restoreFailed
        }
        // 2. Quarantine the rotten original (recoverable; keep its sidecar at the live location).
        try BinStore(vault: drive).moveToBin(relPath: relPath,
            hash: ContentHash(stringValue: expectedHash), origin: .repaired, includeSidecar: false)
        // 3. Place the verified file (dest is now absent → atomic, same-volume rename).
        try fm.moveItem(at: tmp, to: dest)
        // 4. Re-record size/mtime to the placed file (hash stays `expectedHash`).
        try writeManifestEntry(hash: expectedHash, relPath: relPath, fileURL: dest, on: drive)
    }
```

- [ ] **Step 5: Run the tests + full suite + build**

Run: `swift test --filter repairCorrupt --filter binOriginRepairedRoundTrips 2>&1 | tail -15` → PASS (3 tests).
Run: `swift test 2>&1 | tail -3` → full suite green.
Run: `swift build 2>&1 | grep -iE 'warning|error'` → empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenPhotoCore/Vault/BinStore.swift Sources/OpenPhotoCore/Sync/DriftReconciler.swift Tests/OpenPhotoCoreTests/ConsensusRepairTests.swift
git commit -m "$(cat <<'EOF'
feat: DriftReconciler.repairCorrupt — bin-then-replace bit-rot repair

repairCorrupt stages a verified-good copy to a temp on the drive FIRST (a rotten
source throws before anything is binned), quarantines the rotten original to the
drive bin (new BinStore.Origin.repaired, sidecar kept at the live location),
atomically places the verified file, and re-records its size/mtime. Reuses
VerifiedCopy + BinStore. TDD incl. the rotten-source-safety invariant.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: App — sweep + repair actions + per-drive corrupt Repair

**Context:** `AppState.verifyIntegrity(drive:progress:)` is the per-drive template (verify off-main → annotate recoverability → `replaceVaultPresence` → cache in `driveDrift`). `durableVaults` / `driveIsPresent(_:)` / `openVault(for:)` / `presenceService()` / `presenceEntries(forDrive:limitedTo:)` / `reloadCanonicalPresence()` / `refreshPendingDeletions()` all exist. `goodCopyURL(forHash:excluding:)` (private on AppState) resolves a reachable hash-matching copy across the Mac + connected drives. `driftScan(_:)` re-scans + refreshes. `DriftReconciler().restore(relPath:expectedHash:from:on:)` repairs a *missing* file (slot already empty).

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`, `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift`

- [ ] **Step 1: Add the sweep + repair actions to `AppState`**

Add near `verifyIntegrity`:

```swift
    /// Verify every connected durable drive (off-main, with progress), annotate cross-set
    /// recoverability, update presence, and return each drive's report. Drives "Verify All Drives".
    func verifyAllConnected(progress: @escaping @Sendable (String, DriftProgress) -> Void)
        async -> [(vr: VaultRecord, report: DriftReport)] {
        guard let lib = library else { return [] }
        var out: [(VaultRecord, DriftReport)] = []
        for vr in durableVaults where driveIsPresent(vr) {
            cacheDriveKind(vr)
            guard let drive = openVault(for: vr) else { continue }
            let name = (vr.rootPath as NSString).lastPathComponent
            let report = await Task.detached(priority: .userInitiated) {
                (try? DriftReconciler().verify(drive: drive) { p in progress(name, p) }) ?? DriftReport()
            }.value
            var enriched = report
            if let p = presenceService() {
                DriftReconciler().annotateRecoverability(&enriched, driveID: vr.id, presence: p)
            }
            try? lib.catalog.replaceVaultPresence(vaultID: vr.id,
                entries: presenceEntries(forDrive: drive, limitedTo: enriched.presentHashes))
            driveDrift[vr.id] = enriched
            out.append((vr, enriched))
        }
        reloadCanonicalPresence()
        refreshPendingDeletions()
        return out
    }

    /// Repair one finding from the best connected good copy: corrupt → repairCorrupt (bin-then-
    /// replace), missing → restore. Off-main. Returns whether it succeeded.
    @discardableResult
    func repairFinding(_ finding: DriftFinding, on driveVault: Vault) async -> Bool {
        guard let hash = finding.recordedHash,
              let source = goodCopyURL(forHash: hash, excluding: driveVault.descriptor.vaultID)
        else { return false }
        return await Task.detached(priority: .userInitiated) {
            do {
                switch finding.kind {
                case .corrupt:
                    try DriftReconciler().repairCorrupt(relPath: finding.relPath,
                        expectedHash: hash, from: source, on: driveVault)
                case .missing:
                    try DriftReconciler().restore(relPath: finding.relPath,
                        expectedHash: hash, from: source, on: driveVault)
                default: return false   // changed/unknown aren't auto-repaired
                }
                return true
            } catch { return false }
        }.value
    }

    /// Repair every recoverable corrupt+missing finding in `report` on `driveVault`, then one
    /// re-scan. Returns the refreshed report.
    @discardableResult
    func repairAllRecoverable(_ report: DriftReport, on driveVault: Vault) async -> DriftReport {
        let targets = (report.corrupt + report.missing).filter {
            if case .recoverable = $0.recoverability { return true } else { return false }
        }
        for f in targets { _ = await repairFinding(f, on: driveVault) }
        return driftScan(driveVault)
    }
```

(`cacheDriveKind` is the same call `autoScanConnectedDrives` uses; if its name differs, drop that line — it's only a badge refresh.)

- [ ] **Step 2: Add the corrupt Repair button to the per-drive `DriftReviewSheet`**

In `Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift`, split corrupt out of the report-only section into its own repairable section. Replace the `if !(r.changed + r.corrupt).isEmpty { … }` block with:

```swift
            if !r.corrupt.isEmpty {
                let recoverable = r.corrupt.filter { if case .recoverable = $0.recoverability { true } else { false } }
                Section {
                    ForEach(r.corrupt, id: \.relPath) { f in
                        HStack {
                            Text(f.relPath).font(.system(size: 12)); Spacer()
                            HStack(spacing: 8) {
                                recoverabilityLabel(f.recoverability)
                                if case .recoverable = f.recoverability {
                                    Button("Repair") {
                                        Task { _ = await state.repairFinding(f, on: drive); report = state.driftScan(drive) }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Corrupt (bit-rot)"); Spacer()
                        if !recoverable.isEmpty {
                            Button("Repair all") {
                                Task { var rep = DriftReport(); rep.corrupt = recoverable
                                       report = await state.repairAllRecoverable(rep, on: drive) }
                            }.font(.system(size: 11))
                        }
                    }
                }
            }
            if !r.changed.isEmpty {
                Section("Changed (report only — Adopt or Acknowledge per file)") {
                    ForEach(r.changed, id: \.relPath) { f in
                        HStack {
                            Text(f.relPath).font(.system(size: 12)); Spacer()
                            recoverabilityLabel(f.recoverability)
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build (0 warnings)**

Run: `swift build 2>&1 | grep -iE 'warning|error'` → empty.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Drives/DriftReviewSheet.swift
git commit -m "$(cat <<'EOF'
feat: cross-drive verify + repair actions; corrupt Repair in the per-drive sheet

AppState.verifyAllConnected sweeps every connected durable drive; repairFinding
repairs one corrupt (bin-then-replace) or missing (restore) finding from the best
connected good copy off-main; repairAllRecoverable does a drive in one pass. The
per-drive Verify sheet's corrupt findings are no longer report-only — they get a
Repair / Repair-all button when a verified-good copy is reachable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: App — `ConsensusRepairSheet` + "Verify All Drives" entry

**Context:** `DrivesView` presents sheets via `.sheet(item:)` on `@State` Identifiable values (`syncDrive`, `drift`, `deletionDrive`) and has a `mainContent` toolbar with "Add Drive…" / "Quick View Folder…". `DriftReviewSheet` is the list idiom to mirror (`List` + `Section` + `recoverabilityLabel`). `verifyAllConnected` returns `[(vr, report)]`.

**Files:**
- Create: `Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift`
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

- [ ] **Step 1: Create `ConsensusRepairSheet`**

```swift
import SwiftUI
import OpenPhotoCore

/// Cross-drive integrity review: verifies every connected durable drive on appear, groups findings
/// by drive, and offers one-click repair of corrupt + missing files from a verified-good copy
/// anywhere in the connected set (canonical-authoritative; a rotten source fails safe).
struct ConsensusRepairSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var results: [(vr: VaultRecord, report: DriftReport)] = []
    @State private var progress: (drive: String, p: DriftProgress)?
    @State private var running = true
    @State private var confirmRepairAll = false

    private var repairable: [(VaultRecord, DriftFinding)] {
        results.flatMap { r in (r.report.corrupt + r.report.missing)
            .filter { if case .recoverable = $0.recoverability { true } else { false } }
            .map { (r.vr, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Verify all connected drives").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !repairable.isEmpty && !running {
                    Button("Repair all (\(repairable.count))") { confirmRepairAll = true }
                }
                Button("Done") { dismiss() }.disabled(running)
            }.padding(16)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 640, height: 520)
        .task { await verifyAll() }
        .confirmationDialog("Repair \(repairable.count) file\(repairable.count == 1 ? "" : "s")?",
                            isPresented: $confirmRepairAll, titleVisibility: .visible) {
            Button("Repair from verified-good copies") { Task { await repairEverything() } }
        } message: {
            Text("Corrupt files move to their drive's bin (recoverable) and are replaced from a "
               + "hash-verified copy on another connected drive or this Mac. A bad source fails safe.")
        }
    }

    @ViewBuilder private var content: some View {
        if running {
            VStack(spacing: 10) {
                ProgressView(); 
                if let progress {
                    Text("Verifying \(progress.drive)… \(progress.p.done)/\(progress.p.total) · \(progress.p.currentName)")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.allSatisfy({ $0.report.isClean }) {
            VStack(alignment: .leading, spacing: 6) {
                Label("All drives verified", systemImage: "checkmark.seal")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
                Text("Every file on every connected drive matches OpenPhoto's record.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
        } else {
            List {
                ForEach(results.filter { !$0.report.isClean }, id: \.vr.id) { r in
                    Section((r.vr.rootPath as NSString).lastPathComponent) {
                        driveFindings(r.vr, r.report)
                    }
                }
            }.listStyle(.inset)
        }
    }

    @ViewBuilder private func driveFindings(_ vr: VaultRecord, _ report: DriftReport) -> some View {
        ForEach(report.corrupt + report.missing, id: \.relPath) { f in
            HStack {
                Text(f.relPath).font(.system(size: 12)); Spacer()
                kindTag(f.kind)
                switch f.recoverability {
                case .recoverable(let src):
                    Text("from \(src)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Button("Repair") { Task { await repairOne(vr, f) } }
                case .lostNoCopy:
                    Text("⚠️ no good copy — lost").font(.system(size: 11)).foregroundStyle(.red)
                case .unknown:
                    EmptyView()
                }
            }
        }
    }

    private func kindTag(_ k: DriftFinding.Kind) -> some View {
        Text(k == .corrupt ? "corrupt" : "missing")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.25), in: Capsule())
            .foregroundStyle(k == .corrupt ? Theme.amber : Theme.textDim)
    }

    private func verifyAll() async {
        running = true
        results = await state.verifyAllConnected { drive, p in
            Task { @MainActor in progress = (drive, p) }
        }
        progress = nil; running = false
    }

    private func repairOne(_ vr: VaultRecord, _ f: DriftFinding) async {
        guard let drive = state.openVault(for: vr) else { return }
        _ = await state.repairFinding(f, on: drive)
        _ = state.driftScan(drive)
        await refreshResults()
    }

    private func repairEverything() async {
        for r in results where !r.report.isClean {
            guard let drive = state.openVault(for: r.vr) else { continue }
            _ = await state.repairAllRecoverable(r.report, on: drive)
        }
        await refreshResults()
    }

    /// Re-read each drive's cached report after repairs (driftScan already refreshed driveDrift).
    private func refreshResults() async {
        results = results.map { ($0.vr, state.driveDrift[$0.vr.id] ?? $0.report) }
    }
}
```

- [ ] **Step 2: Add the "Verify All Drives" entry point**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, add a `@State private var consensusRepair = false` near the other sheet state, a button in `mainContent`'s toolbar next to "Quick View Folder…":

```swift
                Button("Verify All Drives") { consensusRepair = true }.controlSize(.small)
```

and present the sheet (next to the other `.sheet` modifiers in `body`):

```swift
            .sheet(isPresented: $consensusRepair) { ConsensusRepairSheet(state: state) }
```

- [ ] **Step 3: Build (0 warnings) + rebuild bundle**

Run: `swift build 2>&1 | grep -iE 'warning|error'` → empty.
Run: `./scripts/make-app.sh 2>&1 | tail -3`.

**Manual checklist:** with two+ connected drives, "Verify All Drives" runs across the set with progress; a corrupt file shows "corrupt … from <other drive/Mac>" + Repair; repairing replaces the bytes and bins the rotten original; **repairing a corrupt file on the canonical from a backup works**; a missing file repairs; a `lostNoCopy` file shows "lost", no Repair; "Repair all" confirms then sweeps; the per-drive Verify sheet's corrupt Repair button also works.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenPhotoApp/Drives/ConsensusRepairSheet.swift Sources/OpenPhotoApp/Drives/DrivesView.swift
git commit -m "$(cat <<'EOF'
feat: Verify All Drives — cross-drive consensus repair sheet

A "Verify All Drives" Drives-panel action verifies every connected durable drive
and presents findings grouped by drive: corrupt + missing files get a Repair (and
Repair-all) action sourcing a verified-good copy from anywhere in the connected
set; lost files are surfaced not repaired. Rebuilt the bundle.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Docs — format §8 + master spec §10 + changelog

**Files:**
- Modify: `docs/format/vault-format-v1.md`, `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Document the `repaired` bin origin**

In `docs/format/vault-format-v1.md`, find the §8 bin section describing `bin.jsonl` `origin` values (currently `user` / `propagated`). Add **`repaired`** — "a corrupt (bit-rot) file quarantined when its slot was repaired from a verified-good copy during Verify Integrity; recoverable, never a deletion intent (not propagated, not a pending deletion)."

- [ ] **Step 2: Update §10 + changelog**

In `docs/superpowers/specs/2026-06-07-openphoto-design.md`: mark **multi-drive consensus repair DONE** in §10 (and the `[3.5] Multi-drive consensus repair` backlog item), and add a `2026-06-10` changelog entry (cross-drive Verify; `repairCorrupt` bin-then-replace; `BinStore.Origin.repaired`; canonical repairable from a backup; corrupt+missing repaired, changed stays manual). Note **Phase 3 (Drives) is now fully closed out → next is Phase 4 (Intelligence)**.

- [ ] **Step 3: Commit**

```bash
git add docs/format/vault-format-v1.md docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "$(cat <<'EOF'
docs: consensus repair done — bin origin `repaired` (§8), §10 + changelog

vault-format-v1 §8 documents the new `repaired` bin origin; master-spec §10 marks
multi-drive consensus repair done. Phase 3 (Drives) fully closed out; next is
Phase 4 (Intelligence).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## After all tasks

- [ ] Final whole-slice review: the safe ordering holds (rotten source never bins; verified replacement always staged first); cross-set recoverability + repair work for any drive incl. the canonical; full suite green + 0 warnings.
- [ ] **Do NOT merge.** Report completion; the `multi-drive-consensus-repair` → `main` merge is user-gated.

---

## Self-Review

- **Spec coverage:** §4 `repairCorrupt` → T1. §5 sweep/`verifyAllConnected`/repair actions/combined sheet/per-drive corrupt button → T2 (actions + per-drive button) + T3 (sheet + entry). §7 edges (rotten-source safety, lost, idempotent) → T1 tests + the sheet's recoverability handling. §8 testing → T1 (3 Core tests) + T3 manual. §4 format addition → T1 (`Origin.repaired`) + T4 (§8 doc).
- **Placeholders:** none — Core + key App code complete; the `ConsensusRepairSheet` is full; T4's doc edits describe exact content to add against existing sections.
- **Type consistency:** `repairCorrupt(relPath:expectedHash:from:on:)`; `BinStore.moveToBin(relPath:hash:origin:includeSidecar:)` (default `true` keeps existing callers); `Origin.repaired`; `verifyAllConnected(progress:) -> [(vr:VaultRecord, report:DriftReport)]`; `repairFinding(_:on:) async -> Bool`; `repairAllRecoverable(_:on:) async -> DriftReport`. `DriftFinding.kind`/`.recordedHash`/`.recoverability`, `Recoverability.recoverable(source:)`/`.lostNoCopy`, `DriftReport.corrupt`/`.missing`/`.isClean` all match the Core types. `goodCopyURL`/`driftScan`/`presenceService`/`presenceEntries(forDrive:limitedTo:)` are the existing AppState members reused.
