# Slice 5c — Canonical Management & Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Explicit, safe control over which drive is the canonical — change it (promote a backup, demote the old), recover when it's lost, and migrate to a new drive — all by composing existing copy/role/presence machinery.

**Architecture:** A pure Core agreement gate (`canonicalAgreement` = exact set equality) + recovery-loss math, plus an **atomic** catalog role flip (`Catalog.setCanonical`, one transaction → never zero/two canonicals). AppState orchestrates: planned promotion (manifest re-verify → atomic flip → best-effort `vault.json`), recovery (acknowledged flip → Mac→canonical one-way salvage sync), and a conflict detector (a connected drive whose `vault.json` says canonical but isn't the registered one) that converges to exactly one canonical.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (CLT — `swift build`/`swift test`, no Xcode), Swift Testing, GRDB.

**Spec:** `docs/superpowers/specs/2026-06-10-phase3-slice5c-canonical-management-migration-design.md`
**Branch:** `phase3-drives` — the **last required Phase 3 slice**; after it, the branch merges to `main` (T6 notes this; the merge is **not** performed by the plan).

**Conventions (every task):**
- TDD for Core (T1–T2); App (T3–T5) build-verified + manual. Docs (T6) no code.
- 0 compiler warnings: `swift build 2>&1 | grep -i warning` prints nothing.
- Generated mock files only in temp dirs (`TestDirs`, `makeJPEG`, raw `Data`). **Never** `~/Pictures`/personal folders.
- Do **not** modify `VerifiedCopy`, `Manifest`, the `SyncEngine` copy/verify spine, or the send destinations. **No catalog migration** (`setCanonical` only `UPDATE`s the existing `vaults.role`).
- Each task commits with the exact message shown, ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Confirmed reference APIs (already in the codebase — do not redefine):**
- `Catalog(at: URL)`; `public let dbQueue: DatabaseQueue`; `registerVault(id:role:rootPath:)`, `registeredVaults() -> [VaultRecord]`, `vaultPresenceHashes(forVault:) -> Set<String>`, `instanceHashes() -> Set<String>` (distinct hashes with a LOCAL instance).
- `VaultRecord { id: String; role: String; rootPath: String; lastSeenMs: Int64 }`.
- `Vault.openOrCreate(at:role:)`, `.manifestURL`, `.descriptor.{vaultID,role}`, `.rootURL`; `Vault.writingRole(_ role: VaultRole) throws -> Vault` (atomic vault.json role rewrite). `VaultRole` = `.local`/`.canonical`/`.backup`.
- `Manifest.read(from:) -> [ManifestEntry]`; `ManifestEntry.hash: ContentHash` (`.stringValue`).
- `SyncEngine(library:)`, `.plan(sources: [Vault], destinationVault:) -> SyncPlan`, `.apply(_:destinationVault:volume:event:counterpartyVaultID:progress:) -> SyncResult`; `FileSystemVolume(rootURL:)`; `SyncPlan()`.
- `CatalogSnapshot.write(catalog:thumbnails:drive:)`.
- `AppState`: `library`, `durableVaults`, `canonicalVault: VaultRecord?`, `openVault(for:) -> Vault?`, `driveIsPresent(_:) -> Bool`, `reloadDrives()`, `reloadCanonicalPresence()`, `refreshCanonicalPresence(driveVault:)`, `refreshQueries()`, `forgetDrive(_:)`.

---

## Task 1: Core agreement + recovery-loss helpers

**Files:**
- Create: `Sources/OpenPhotoCore/Sync/CanonicalManagement.swift`
- Test: `Tests/OpenPhotoCoreTests/CanonicalManagementTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenPhotoCoreTests/CanonicalManagementTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func h(_ c: Character) -> String { "sha256:" + String(repeating: c, count: 64) }

@Test func agreementIsExactSetEquality() {
    #expect(canonicalAgreement(canonicalHashes: [h("a"), h("b")], backupHashes: [h("a"), h("b")]))
    #expect(!canonicalAgreement(canonicalHashes: [h("a"), h("b")], backupHashes: [h("a")]))         // missing
    #expect(!canonicalAgreement(canonicalHashes: [h("a")], backupHashes: [h("a"), h("b")]))         // extra
    #expect(canonicalAgreement(canonicalHashes: [], backupHashes: []))
}

@Test func recoveryLossSplitsAtRiskByMacAvailability() {
    let r = recoveryLoss(lostCanonicalHashes: [h("a"), h("b"), h("c")],
                         backupHashes: [h("a")], macLocalHashes: [h("b")])
    #expect(r == RecoveryLoss(recoverableFromMac: 1, lost: 1))   // atRisk={b,c}; b on Mac, c lost
}

@Test func recoveryLossZeroWhenBackupHasEverything() {
    let r = recoveryLoss(lostCanonicalHashes: [h("a"), h("b")],
                         backupHashes: [h("a"), h("b")], macLocalHashes: [])
    #expect(r == RecoveryLoss(recoverableFromMac: 0, lost: 0))
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter CanonicalManagementTests 2>&1 | tail -20`
Expected: compile failure — `canonicalAgreement`/`recoveryLoss`/`RecoveryLoss` don't exist.

- [ ] **Step 3: Implement the helpers**

Create `Sources/OpenPhotoCore/Sync/CanonicalManagement.swift`:

```swift
import Foundation

/// A backup is promotable to canonical only when its content is an EXACT copy of the canonical —
/// the same hashes, nothing missing and nothing extra. (Extra = an un-applied deletion the backup
/// still holds; promoting it would resurrect a deleted photo. Missing = behind on additions.)
public func canonicalAgreement(canonicalHashes: Set<String>, backupHashes: Set<String>) -> Bool {
    canonicalHashes == backupHashes
}

/// How a recovery (promoting a backup when the canonical is lost) splits the photos that were on the
/// lost canonical but not on the backup: those the Mac still holds locally (recoverable via the
/// one-way Mac→canonical sync) vs those reachable nowhere (genuinely lost).
public struct RecoveryLoss: Sendable, Equatable {
    public var recoverableFromMac: Int
    public var lost: Int
    public init(recoverableFromMac: Int, lost: Int) {
        self.recoverableFromMac = recoverableFromMac; self.lost = lost
    }
}

public func recoveryLoss(lostCanonicalHashes: Set<String>, backupHashes: Set<String>,
                         macLocalHashes: Set<String>) -> RecoveryLoss {
    let atRisk = lostCanonicalHashes.subtracting(backupHashes)
    return RecoveryLoss(recoverableFromMac: atRisk.intersection(macLocalHashes).count,
                        lost: atRisk.subtracting(macLocalHashes).count)
}
```

- [ ] **Step 4: Run — verify pass + no warnings**

Run: `swift test --filter CanonicalManagementTests 2>&1 | tail -10` → all pass.
Run: `swift build 2>&1 | grep -i warning` → no output.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Sync/CanonicalManagement.swift Tests/OpenPhotoCoreTests/CanonicalManagementTests.swift
git commit -m "feat(core): canonicalAgreement (exact-equality gate) + recoveryLoss math

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Catalog.setCanonical` (atomic role flip)

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift`
- Test: `Tests/OpenPhotoCoreTests/CanonicalManagementTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CanonicalManagementTests.swift`:

```swift
@Test func setCanonicalFlipsBothRolesAtomically() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "A", role: "canonical", rootPath: "/A")
    try cat.registerVault(id: "B", role: "backup", rootPath: "/B")

    try cat.setCanonical("B", demoting: "A")

    let roles = Dictionary(try cat.registeredVaults().map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
    #expect(roles["B"] == "canonical")
    #expect(roles["A"] == "backup")
    #expect(try cat.registeredVaults().filter { $0.role == "canonical" }.count == 1)   // exactly one
}

@Test func setCanonicalNilDemotionOnlyPromotes() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.registerVault(id: "B", role: "backup", rootPath: "/B")
    try cat.setCanonical("B", demoting: nil)
    #expect(try cat.registeredVaults().first { $0.id == "B" }?.role == "canonical")
}
```

- [ ] **Step 2: Run — verify failure**

Run: `swift test --filter CanonicalManagementTests 2>&1 | tail -15`
Expected: compile failure — `setCanonical` doesn't exist.

- [ ] **Step 3: Implement `setCanonical`**

In `Sources/OpenPhotoCore/Catalog/Catalog.swift`, after `registerVault`/`unregisterVault`:

```swift
    /// Atomically designate `newID` the canonical and (if given) demote `oldID` to backup — one
    /// transaction, so the catalog never momentarily has zero or two canonicals. The drives'
    /// `vault.json` self-descriptions are reconciled separately (best-effort); the catalog role is
    /// authoritative for "which drive is THE canonical".
    public func setCanonical(_ newID: String, demoting oldID: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE vaults SET role = 'canonical' WHERE id = ?", arguments: [newID])
            if let oldID {
                try db.execute(sql: "UPDATE vaults SET role = 'backup' WHERE id = ?", arguments: [oldID])
            }
        }
    }
```

- [ ] **Step 4: Run — verify pass + no warnings + full suite**

Run: `swift test --filter CanonicalManagementTests 2>&1 | tail -10` → all pass.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Tests/OpenPhotoCoreTests/CanonicalManagementTests.swift
git commit -m "feat(core): Catalog.setCanonical atomically flips canonical/backup roles

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Promotability + planned promotion (AppState)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

App glue → build-verified (the flip mechanics are exercised by Core tests; AppState orchestrates). Add near the other drive helpers (e.g. after `cloneToBackup`/`backupBehindCount`).

- [ ] **Step 1: Add `isPromotable` + `promoteToCanonical`**

```swift
    /// A backup is promotable iff it's connected, the canonical is connected, and their content sets
    /// are exactly equal (cheap presence-set gate; promotion re-verifies via manifests).
    func isPromotable(_ vr: VaultRecord) -> Bool {
        guard let lib = library, vr.role == "backup", driveIsPresent(vr),
              let canon = canonicalVault, driveIsPresent(canon) else { return false }
        let canonHashes = (try? lib.catalog.vaultPresenceHashes(forVault: canon.id)) ?? []
        let backupHashes = (try? lib.catalog.vaultPresenceHashes(forVault: vr.id)) ?? []
        return canonicalAgreement(canonicalHashes: canonHashes, backupHashes: backupHashes)
    }

    /// Promote a backup to canonical (planned): re-verify exact agreement against BOTH manifests, then
    /// atomically flip the catalog roles (new→canonical, old→backup) and rewrite the drives' vault.json
    /// best-effort. Returns false (no change) if the backup is not an exact copy — the caller tells the
    /// user to "Update backup" first.
    @discardableResult
    func promoteToCanonical(_ vr: VaultRecord) async -> Bool {
        guard let lib = library, let oldVR = canonicalVault,
              driveIsPresent(vr), driveIsPresent(oldVR),
              let newVault = openVault(for: vr), let oldVault = openVault(for: oldVR) else { return false }
        let agree = await Task.detached(priority: .userInitiated) { () -> Bool in
            let newHashes = Set((try? Manifest.read(from: newVault.manifestURL))?.map { $0.hash.stringValue } ?? [])
            let oldHashes = Set((try? Manifest.read(from: oldVault.manifestURL))?.map { $0.hash.stringValue } ?? [])
            return canonicalAgreement(canonicalHashes: oldHashes, backupHashes: newHashes)
        }.value
        guard agree else { return false }
        try? lib.catalog.setCanonical(vr.id, demoting: oldVR.id)   // atomic catalog flip
        _ = try? newVault.writingRole(.canonical)                  // best-effort on-disk self-describe
        _ = try? oldVault.writingRole(.backup)
        reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
        return true
    }
```

- [ ] **Step 2: Build clean**

Run: `swift build 2>&1 | tail -3` → clean.
Run: `swift build 2>&1 | grep -i warning` → no output.
Run: `swift test 2>&1 | tail -5` → full suite green (no behavior change to existing flows).

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): promoteToCanonical — manifest-verified exact-agreement gate + atomic role flip

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Recovery (AppState)

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`

- [ ] **Step 1: Add `recoveryAcknowledgment` + `recoverCanonical`**

```swift
    /// When the registered canonical is NOT connected (lost/failed but not yet forgotten), the
    /// precise data-loss picture of recovering from backup `vr`: how many at-risk photos the Mac can
    /// still supply vs how many are lost. nil if there is no registered canonical (already forgotten).
    func recoveryAcknowledgment(_ vr: VaultRecord) -> RecoveryLoss? {
        guard let lib = library, let lostCanon = canonicalVault, !driveIsPresent(lostCanon) else { return nil }
        let lostHashes = (try? lib.catalog.vaultPresenceHashes(forVault: lostCanon.id)) ?? []
        let backupHashes = (try? lib.catalog.vaultPresenceHashes(forVault: vr.id)) ?? []
        let macLocalHashes = (try? lib.catalog.instanceHashes()) ?? []
        return recoveryLoss(lostCanonicalHashes: lostHashes, backupHashes: backupHashes,
                            macLocalHashes: macLocalHashes)
    }

    /// Recovery: promote backup `vr` to canonical when the old canonical is absent (acknowledged by
    /// the caller). Flip the catalog roles (the absent old → backup in the catalog; its vault.json is
    /// reconciled on reconnect by the conflict detector), then SALVAGE everything the Mac still holds
    /// via the existing one-way Mac→canonical sync.
    func recoverCanonical(_ vr: VaultRecord) async {
        guard let lib = library, let newVault = openVault(for: vr) else { return }
        let lostID = canonicalVault?.id
        try? lib.catalog.setCanonical(vr.id, demoting: lostID)
        _ = try? newVault.writingRole(.canonical)
        let engine = SyncEngine(library: lib)
        await Task.detached(priority: .userInitiated) {
            let plan = (try? engine.plan(sources: lib.vaults, destinationVault: newVault)) ?? SyncPlan()
            _ = await engine.apply(plan, destinationVault: newVault,
                                   volume: FileSystemVolume(rootURL: newVault.rootURL))
        }.value
        try? refreshCanonicalPresence(driveVault: newVault)
        let cat = lib.catalog, thumbs = lib.thumbnails
        await Task.detached(priority: .utility) { try? CatalogSnapshot.write(catalog: cat, thumbnails: thumbs, drive: newVault) }.value
        reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
    }
```

- [ ] **Step 2: Build clean + commit**

Run: `swift build 2>&1 | tail -3` → clean; `swift build 2>&1 | grep -i warning` → empty; `swift test 2>&1 | tail -5` → green.

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): recoverCanonical — acknowledged promote + Mac→canonical salvage sync

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Conflict detector + Drives-panel UI

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift`
- Modify: `Sources/OpenPhotoApp/Drives/DrivesView.swift`

Build-verified + manual.

- [ ] **Step 1: Add the conflict detector + resolution (AppState)**

```swift
    /// A connected drive whose on-disk vault.json says it's canonical but which ISN'T the registered
    /// canonical — a leftover from a recovery (the old drive turned up) or a partial flip. Surfaced to
    /// the user for confirmed resolution; the catalog's registered canonical stays authoritative.
    var conflictingCanonical: VaultRecord? {
        durableVaults.first { vr in
            driveIsPresent(vr) && vr.id != canonicalVault?.id
            && (openVault(for: vr)?.descriptor.role == .canonical)
        }
    }

    /// Resolve a canonical conflict: demote the stray drive to a backup (reconcile catalog + vault.json),
    /// or forget it. Never leaves two canonicals.
    func resolveCanonicalConflict(_ vr: VaultRecord, makeBackup: Bool) {
        guard let lib = library else { return }
        if makeBackup {
            try? lib.catalog.registerVault(id: vr.id, role: "backup", rootPath: vr.rootPath)
            _ = try? openVault(for: vr)?.writingRole(.backup)
            reloadDrives(); reloadCanonicalPresence(); try? refreshQueries()
        } else {
            forgetDrive(vr)
        }
    }
```

- [ ] **Step 2: Wire the Drives-panel affordances (DrivesView)**

In `Sources/OpenPhotoApp/Drives/DrivesView.swift`, for a connected **backup** drive row, add a **"Make this the canonical"** action (next to the existing "Update backup" / role label):

- If `state.isPromotable(vr)` → confirm, then `Task { if await state.promoteToCanonical(vr) == false { /* show an alert: "This backup is no longer an exact copy of the canonical — run Update backup first." */ } }`.
- If the canonical is **not connected** (`state.canonicalVault.map { !state.driveIsPresent($0) } ?? false`) → instead present the **guided prompt**: *"Plug in your current canonical ('\(canonName)') so OpenPhoto can confirm this backup is a complete, current copy before switching — or, if your canonical is lost, recover from this backup instead."* with a **Recover…** button that opens a recovery confirm showing `state.recoveryAcknowledgment(vr)` (e.g. *"\(r.recoverableFromMac) will be copied from this Mac; \(r.lost) cannot be recovered."*, or a generic line if it returns nil), and on confirm `Task { await state.recoverCanonical(vr) }`.
- If the canonical IS connected but `!isPromotable` → the "Make this the canonical" action shows "This backup isn't an exact copy yet — Update backup first" (disabled or an info alert).

Use `@State` locals + `.alert`/`.confirmationDialog` mirroring the **5b adoption prompt pattern** already in this file. Keep the role label (Canonical/Backup) from 5a/5b.

- [ ] **Step 3: Wire the conflict prompt (DrivesView)**

Add an `.alert` driven by `state.conflictingCanonical` (a `@State var canonicalConflict: VaultRecord?` set on `.onChange(of: state.conflictingCanonical?.id)` / `.onAppear`, with a session-dismiss `Set<String>` like the adoption prompt): *"'\(name)' was your previous canonical; '\(currentCanonName)' is canonical now. Make it a backup (it'll need updating), or Forget it?"* — **Make a backup** → `state.resolveCanonicalConflict(vr, makeBackup: true)`; **Forget** → `state.resolveCanonicalConflict(vr, makeBackup: false)`.

- [ ] **Step 4: Build clean + rebuild bundle + manual**

Run: `swift build 2>&1 | tail -3` and `swift build 2>&1 | grep -i warning` → clean, no warnings.
Run: `swift test 2>&1 | tail -5` → green.
Run: `./scripts/make-app.sh 2>&1 | tail -2` → rebuild the bundle.

Manual (user): a connected backup that exactly matches offers "Make this the canonical" → after, roles swap (Backup↔Canonical) and `vault.json`s update; a behind backup is blocked with "Update backup first"; with the canonical unplugged you get the plug-in guidance + a Recover path showing the loss counts; reconnecting an old (recovered-past) canonical raises the conflict prompt.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift Sources/OpenPhotoApp/Drives/DrivesView.swift
git commit -m "feat(app): Make-this-the-canonical + recovery + canonical-conflict resolution in the Drives panel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Docs — master spec §5.5 + changelog

**Files:**
- Modify: `docs/superpowers/specs/2026-06-07-openphoto-design.md`

- [ ] **Step 1: Update §5.5 (Migration)**

Replace/expand the §5.5 body to describe canonical management as implemented: exactly one canonical (catalog role authoritative); **change** via "Make this the canonical" on a backup, gated on **exact agreement** (re-verified against both manifests), flipped **atomically in the catalog** (promote-new + demote-old in one transaction) with best-effort `vault.json` self-description; **recovery** when the canonical is absent (acknowledged data-loss with precise counts when its contents are still known, then a Mac→canonical one-way **salvage** sync recovers everything the Mac still holds); **reappearing-old-canonical** conflict resolution (a connected drive claiming canonical but not the registered one → confirmed demote-to-backup or forget); **migration = compose** add (5b) + clone/update (5a) + promote (5c). Note **Mac-as-canonical-target is deferred** (the Mac is role `local`).

- [ ] **Step 2: Add the changelog entry** (after the most recent 2026-06-10 bullet):

```markdown
- **2026-06-10** — Phase 3 **Slice 5c (Canonical management & migration)** implemented on `phase3-drives` — the **last required Phase 3 slice**. The user can now **change which drive is the canonical**: "Make this the canonical" on a connected backup, gated on **exact agreement** (`canonicalAgreement` — the backup must hold *exactly* the canonical's hashes; re-verified against both `manifest.jsonl`s at promotion time), flipped **atomically in the catalog** (`Catalog.setCanonical` — promote-new + demote-old in one transaction, so there's never zero/two canonicals) with best-effort `vault.json` rewrites (`Vault.writingRole`). When the canonical is absent the action **guides plugging it in**; if it's truly lost, a confirmed **recovery** promotes a backup as the new canonical with an **acknowledged data-loss summary** (`recoveryLoss` — how many at-risk photos the Mac can still supply vs are lost) and then a **Mac→canonical one-way salvage sync** recovers everything the Mac still holds (no merge logic — the canonical only ever *receives* from the Mac). A **reappearing old canonical** (a connected drive whose `vault.json` says canonical but which isn't the registered one) is detected and resolved by a confirmed **demote-to-backup or forget** — exactly-one-canonical always converges. **Migration** to a new/bigger drive is pure composition: add (5b) → clone/Update (5a) → promote (5c) → old demotes to backup (or forget). **No new on-disk artifact, no catalog migration** (`setCanonical` only updates `vaults.role`). *Deferred:* migrating the canonical onto the Mac itself (role `local` — a different model). Spec: `docs/superpowers/specs/2026-06-10-phase3-slice5c-canonical-management-migration-design.md`. **Phase 3 (Drives) is now complete** — next: merge `phase3-drives` → `main`. (Slice 5d Quick View remains optional/after.)
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-07-openphoto-design.md
git commit -m "docs: record Slice 5c (canonical management & migration); Phase 3 complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

After T6: a final whole-slice review, then **superpowers:finishing-a-development-branch** to merge `phase3-drives` → `main` (verify the full suite green first). The merge itself is a separate, user-gated step — do not perform it inside this plan.

---

## Self-review notes

- **Spec coverage:** §3 agreement gate → T1 (`canonicalAgreement`) + T3 (`isPromotable`/manifest re-verify); §4 planned promotion → T2 (`setCanonical`) + T3 (`promoteToCanonical`); §5 recovery → T1 (`recoveryLoss`) + T4 (`recoveryAcknowledgment`/`recoverCanonical`); §6 conflict → T5 (`conflictingCanonical`/`resolveCanonicalConflict`); §7 migration = composition (no new code; documented T6); §10 testing → T1–T2 tests. No gaps.
- **Type consistency:** `canonicalAgreement(canonicalHashes:backupHashes:)`, `RecoveryLoss{recoverableFromMac,lost}`, `recoveryLoss(lostCanonicalHashes:backupHashes:macLocalHashes:)`, `Catalog.setCanonical(_:demoting:)`, `isPromotable(_:)`, `promoteToCanonical(_:)`, `recoveryAcknowledgment(_:)`, `recoverCanonical(_:)`, `conflictingCanonical`, `resolveCanonicalConflict(_:makeBackup:)` are used identically across tasks.
- **No catalog migration**, no format change. The atomic flip + best-effort `vault.json` + conflict detector together guarantee exactly-one-canonical.
```
