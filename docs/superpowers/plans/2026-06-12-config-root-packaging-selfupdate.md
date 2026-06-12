# Configurable Root, Packaging & Self-Update — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenPhoto an installable, shareable macOS app: point it at any folder (e.g. `~/Pictures`) and change it from Settings; package it as a versioned DMG with a correct icon and a one-step install to `/Applications`; and have it self-update from GitHub via Sparkle.

**Architecture:** Three independent slices. **A** adds in-app single-root switching by making `AppState.openLibrary` re-entrant and adding a `Catalog.purgeLocalVault` GC. **B** turns `make-app.sh` into a versioned release pipeline (`VERSION` file → Info.plist; multi-size icon regeneration; `install.sh`/`make-dmg.sh`). **C** integrates Sparkle (EdDSA-signed appcast on GitHub Pages, releases on GitHub Releases) plus thorough `RELEASING.md`/`DISTRIBUTING.md` docs.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM, GRDB (SQLite catalog), `swift-testing`, `hdiutil`/`sips`/`iconutil`/`codesign`, Sparkle 2.x, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-06-12-config-root-packaging-selfupdate-design.md`

**Branch:** Work on `feature/packaging-selfupdate` in the **main working directory** (not a separate worktree): the build injects gitignored multi-GB `.models/` that only exist in this checkout, and the user smoke-tests here. Merge to `main` at the end (matching the existing "Merge Phase 5.5 slice N into main" pattern).

---

## File Structure

**Slice A — Configurable root**
- Modify `Sources/OpenPhotoCore/Catalog/Catalog.swift` — add `purgeLocalVault(id:)`.
- Create `Tests/OpenPhotoCoreTests/PurgeLocalVaultTests.swift` — unit test for the GC.
- Modify `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift` — add `stop()`.
- Modify `Sources/OpenPhotoApp/AppState.swift` — `closeLibrary()`, re-entrant `openLibrary`, `changeRoot(to:)`, `configuredRoot`.
- Modify `Sources/OpenPhotoApp/Welcome/WelcomeView.swift` — single-folder picker.
- Modify `Sources/OpenPhotoApp/Settings/SettingsView.swift` — "Library" tab.
- Modify `Sources/OpenPhotoApp/OpenPhotoApp.swift` — `File → Library…` command; missing-root fallback.

**Slice B — Packaging & icon**
- Create `VERSION`.
- Modify `scripts/make-app.sh` — version/build-number injection; icon regeneration as primary path.
- Create `scripts/install.sh`, `scripts/make-dmg.sh`.

**Slice C — Self-update**
- Modify `Package.swift` — add Sparkle dependency.
- Modify `Sources/OpenPhotoApp/OpenPhotoApp.swift` — updater controller + "Check for Updates…".
- Modify `scripts/make-app.sh` — embed/sign `Sparkle.framework`; Sparkle Info.plist keys.
- Create `scripts/release.sh`.
- Create `docs/RELEASING.md`, `docs/DISTRIBUTING.md`; modify `README.md`, `docs/manual-test-checklist.md`.

---

## Slice A — Configurable library root

### Task A1: `Catalog.purgeLocalVault(id:)` + test

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog.swift` (add method after `unregisterVault`, ~line 240)
- Test: `Tests/OpenPhotoCoreTests/PurgeLocalVaultTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/OpenPhotoCoreTests/PurgeLocalVaultTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPhotoCore

private func makeCatalog(_ t: TestDirs) throws -> Catalog {
    try Catalog(at: try t.sub("as").appendingPathComponent("catalog.sqlite"))
}

private func asset(_ h: String) -> AssetRecord {
    AssetRecord(hash: h, kind: "photo", takenAtMs: 1, pixelWidth: nil, pixelHeight: nil,
        latitude: nil, longitude: nil, cameraModel: nil, lensModel: nil, durationSeconds: nil,
        livePairHash: nil, isLivePairedVideo: false, favorite: false, rating: 0,
        caption: nil, tagsJSON: "[]")
}

@Test func purgeLocalVaultRemovesItsInstancesRegistrationAndOrphanAssets() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let c = try makeCatalog(t)
    let hLocal = "sha256:" + String(repeating: "a", count: 64)   // only in the local vault
    let hShared = "sha256:" + String(repeating: "b", count: 64)  // also on a drive

    try c.upsert(assets: [asset(hLocal), asset(hShared)])
    try c.registerVault(id: "v-local", role: "local", rootPath: "/tmp/pics")
    try c.replaceInstances(inVault: "v-local", with: [
        InstanceRecord(hash: hLocal, vaultID: "v-local", relPath: "a.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
        InstanceRecord(hash: hShared, vaultID: "v-local", relPath: "b.jpg",
                       dirPath: "", size: 1, mtimeMs: 1),
    ])
    // hShared is also present on a drive vault, so it must survive the purge.
    try c.registerVault(id: "v-drive", role: "canonical", rootPath: "/Volumes/Canon")
    try c.replaceVaultPresence(vaultID: "v-drive", entries: [
        VaultPresenceEntry(hash: hShared, relPath: "b.jpg", dirPath: "",
                           size: 1, driveRelPath: "b.jpg")])

    try c.purgeLocalVault(id: "v-local")

    // Vault gone, its instances gone, its photos leave the timeline.
    #expect(try c.registeredVaults().contains { $0.id == "v-local" } == false)
    #expect(try c.timelineItems().isEmpty)
    // hLocal is fully orphaned → its asset row is GC'd; hShared survives (drive presence).
    #expect(try c.assetHashes() == [hShared])
    // The drive vault is untouched.
    #expect(try c.registeredVaults().contains { $0.id == "v-drive" })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PurgeLocalVaultTests`
Expected: FAIL — `value of type 'Catalog' has no member 'purgeLocalVault'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/OpenPhotoCore/Catalog/Catalog.swift`, after `unregisterVault` (~line 240):

```swift
    /// Remove a *local* vault entirely: its instances, its registration/presence, and any per-hash
    /// derived rows left with no backing instance AND no drive presence. Drive-only assets (tracked
    /// via another vault's `vault_presence`) are preserved. Files on disk are untouched; everything
    /// removed here is rebuildable by rescanning the folder. Used by "switch library".
    public func purgeLocalVault(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM instances WHERE vaultID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vaults WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vault_presence WHERE vaultID = ?", arguments: [id])
            let orphan = """
                hash NOT IN (SELECT hash FROM instances)
                AND hash NOT IN (SELECT hash FROM vault_presence)
                """
            for table in ["assets", "faces", "embeddings", "phash", "geocode",
                          "derivation_jobs", "finder_tag_sync", "ocr"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE \(orphan)")
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PurgeLocalVaultTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoCore/Catalog/Catalog.swift Tests/OpenPhotoCoreTests/PurgeLocalVaultTests.swift
git commit -m "feat(catalog): purgeLocalVault — drop a local vault + GC its orphaned rows"
```

### Task A2: `DeviceWatcher.stop()` for teardown

**Files:**
- Modify: `Sources/OpenPhotoApp/Devices/DeviceWatcher.swift` (add after `start()`, ~line 89)

- [ ] **Step 1: Add `stop()`**

```swift
    /// Tear down everything `start()` set up, so the watcher can be cleanly restarted when the user
    /// switches libraries. Idempotent.
    func stop() {
        browser.stop()
        browser.delegate = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        for src in sourceCache.values { src.close() }
        sourceCache.removeAll()
        cameras.removeAll()
        devices.removeAll()
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Devices/DeviceWatcher.swift
git commit -m "feat(devices): DeviceWatcher.stop() for clean library teardown"
```

### Task A3: Re-entrant `openLibrary` + `closeLibrary` + `changeRoot`

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (`configuredRoots`/`openLibrary` ~lines 1298-1361; `startWatcher` ~1658)

- [ ] **Step 1: Add a single-root accessor next to `configuredRoots` (~line 1298)**

```swift
    /// The one configured local library folder (single-root model), or nil on first run.
    var configuredRoot: URL? { configuredRoots.first }
```

- [ ] **Step 2: Make `openLibrary` re-entrant — at the very top of `openLibrary(roots:)` (line 1303), before the `UserDefaults.standard.set(...)` line, insert:**

```swift
        closeLibrary()   // tear down any previously-open library so this can be called to switch
```

- [ ] **Step 3: Add `closeLibrary()` and `changeRoot(to:)` immediately after `openLibrary`'s closing brace (after line 1361)**

```swift
    /// Tear the open library down to the pre-open state (back to the Welcome screen). Safe to call
    /// when nothing is open. Does NOT touch the persisted root or any files — purely in-memory.
    func closeLibrary() {
        watcher?.stop(); watcher = nil
        deviceWatcher.stop()
        library = nil
        openedItem = nil; openedDevice = nil; peekContext = nil
        sections = []; flatItems = []; folderTree = []; binEntries = []
        selectedFolder = nil; selection = .timeline
        refreshToken &+= 1
    }

    /// Switch the library to a different single root: forget the old local vault's catalog rows
    /// (rebuildable — files and XMP sidecars are untouched), then open the new folder live.
    func changeRoot(to newRoot: URL) {
        if let current = configuredRoot, current.standardizedFileURL == newRoot.standardizedFileURL {
            return   // same folder — no-op
        }
        if let lib = library {
            for v in lib.vaults where v.descriptor.role == .local {
                try? lib.catalog.purgeLocalVault(id: v.descriptor.vaultID)
            }
        }
        openLibrary(roots: [newRoot])
    }

    /// Return to the Welcome screen and forget the configured root (used by "Close Library").
    func closeLibraryAndForgetRoot() {
        closeLibrary()
        UserDefaults.standard.removeObject(forKey: Self.rootsDefaultsKey)
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build`
Expected: Builds cleanly. (If `Vault.descriptor.role` isn't `.local`-comparable, confirm the enum case name with `grep -n "enum.*Role\|case local" Sources/OpenPhotoCore/Vault/*.swift` and adjust.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenPhotoApp/AppState.swift
git commit -m "feat(app): re-entrant openLibrary + closeLibrary/changeRoot for in-app root switching"
```

### Task A4: Simplify `WelcomeView` to a single folder

**Files:**
- Modify: `Sources/OpenPhotoApp/Welcome/WelcomeView.swift` (replace whole file)

- [ ] **Step 1: Replace the file with a single-folder picker**

```swift
import SwiftUI
import OpenPhotoCore

struct WelcomeView: View {
    @Bindable var state: AppState
    @State private var root: URL?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Welcome to OpenPhoto").font(.system(size: 24, weight: .bold))
            Text("Your photos stay exactly where they are — regular files in regular folders.\nOpenPhoto only indexes them. Delete the app and your library is untouched.")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                if let root {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(root.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                    }
                    .padding(10)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
                }
                Button { chooseFolder() } label: {
                    Label(root == nil ? "Choose your photo folder…" : "Choose a different folder…",
                          systemImage: "plus")
                        .frame(maxWidth: .infinity).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.hairline, style: .init(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain)
            }
            .frame(width: 460)

            Button("Open library") { if let root { state.openLibrary(roots: [root]) } }
                .buttonStyle(.borderedProminent)
                .disabled(root == nil)

            Text("Tip: choose your Pictures folder. Don't choose the Photos Library — that's Apple's internal database.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK { root = panel.urls.first }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenPhotoApp/Welcome/WelcomeView.swift
git commit -m "feat(welcome): single-folder root picker"
```

### Task A5: Settings "Library" tab + `File → Library…` command + missing-root fallback

**Files:**
- Modify: `Sources/OpenPhotoApp/Settings/SettingsView.swift`
- Modify: `Sources/OpenPhotoApp/OpenPhotoApp.swift`

- [ ] **Step 1: Add a "Library" tab to `SettingsView`. Insert before `about` in the `TabView` (after line 12):**

```swift
            library
                .tabItem { Label("Library", systemImage: "folder") }
```

- [ ] **Step 2: Add the `library` view to `SettingsView` (after the `general` computed property, ~line 31):**

```swift
    private var library: some View {
        Form {
            Text("Library folder").font(.system(size: 12, weight: .semibold))
            HStack {
                Image(systemName: "folder").foregroundStyle(Theme.accent)
                Text(state.configuredRoot?.path ?? "No folder chosen")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Change…") { changeRootViaPanel() }
                Button("Close Library") { state.closeLibraryAndForgetRoot() }
                    .disabled(state.library == nil)
            }
            Text("Switching forgets OpenPhoto's index of the old folder and indexes the new one. Your photo files and any edits (favorites, tags, captions, people) are never touched — they live with the files.")
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private func changeRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.configuredRoot
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.message = "Choose the folder OpenPhoto should index."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        let alert = NSAlert()
        alert.messageText = "Switch OpenPhoto to “\(url.lastPathComponent)”?"
        alert.informativeText = "Photos from your current folder will be removed from OpenPhoto's views. Your files and edits are not touched."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.changeRoot(to: url) }
    }
```

- [ ] **Step 3: Add a `File → Library…` menu command. In `OpenPhotoApp.swift`, inside the existing `CommandGroup(after: .newItem)` (after line 36, after the "Export Metadata Sidecars…" button):**

```swift
                Divider()
                Button("Library…") {
                    MainActor.assumeIsolated {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
```

(Opens the Settings window; the user clicks the Library tab. Opening directly to a tab isn't supported by SwiftUI `Settings` — keep it simple.)

- [ ] **Step 4: Missing-root fallback at launch. In `OpenPhotoApp.swift`, replace the `.task` body (lines 14-17) with:**

```swift
                .task {
                    guard let root = state.configuredRoot else { return }   // → Welcome
                    if FileManager.default.fileExists(atPath: root.path) {
                        state.openLibrary(roots: [root])
                    }
                    // If the saved folder is missing (moved/unplugged), fall through to Welcome
                    // without forgetting it — it may reappear; the user can re-open via Welcome.
                }
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build`
Expected: Builds cleanly. (If `showSettingsWindow:` selector warns on the target macOS, fall back to `Selector(("showPreferencesWindow:"))` — try `showSettingsWindow:` first; it's the macOS 14+ name.)

- [ ] **Step 6: Manual smoke**

Run: `swift run OpenPhotoApp`
- Settings (⌘,) → Library tab shows the current folder; **Change…** opens a picker + confirm, switches live; old photos leave, new appear, no restart.
- **Close Library** returns to Welcome.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenPhotoApp/Settings/SettingsView.swift Sources/OpenPhotoApp/OpenPhotoApp.swift
git commit -m "feat(settings): Library tab to change/close the root; File > Library command; missing-root fallback"
```

---

## Slice B — Packaging, install & icon

### Task B1: `VERSION` file + version/build injection + icon regeneration in `make-app.sh`

**Files:**
- Create: `VERSION`
- Modify: `scripts/make-app.sh`

- [ ] **Step 1: Create `VERSION`**

```
0.1.0
```

- [ ] **Step 2: In `make-app.sh`, after `swift build -c release` (line 6), add version derivation:**

```bash
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD)"   # monotonically increasing; Sparkle compares this
```

- [ ] **Step 3: In the Info.plist heredoc, replace the hardcoded version/build lines:**

Replace:
```
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
```
with:
```
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__BUILD__</string>
```
Then, immediately after the `PLIST` heredoc closes, substitute the tokens:
```bash
sed -i '' "s/__VERSION__/${VERSION}/; s/__BUILD__/${BUILD}/" "$APP/Contents/Info.plist"
```

- [ ] **Step 4: Make multi-size icon regeneration the PRIMARY path (fixes the blank Stage-Manager icon).** Replace the entire icon block (lines 33-54, the `PREBUILT_ICNS … fi`) with:

```bash
# App icon — always build a FULL multi-resolution .icns from a 1024px source. (A single-rep .icns
# renders blank in surfaces that request a small rep, e.g. the minimized/Stage-Manager strip.)
ICON_SRC="IconKitchen-Output/macos/AppIcon1024.png"
[[ -f "$ICON_SRC" ]] || ICON_SRC="$(ls -t OpenPhoto-*-1024x1024@1x.png 2>/dev/null | grep -v -- '-old' | head -1)"
if [[ -n "${ICON_SRC:-}" && -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/OpenPhoto.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenPhoto.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "Built multi-size OpenPhoto.icns from $ICON_SRC"
else
  echo "warning: no 1024px icon source found — app will use the generic icon"
fi
```

- [ ] **Step 5: Build and verify the icns has multiple representations**

Run: `./scripts/make-app.sh && iconutil -l build/OpenPhoto.app/Contents/Resources/OpenPhoto.icns 2>/dev/null || sips -g pixelWidth build/OpenPhoto.app/Contents/Resources/OpenPhoto.icns`
Run: `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/OpenPhoto.app/Contents/Info.plist`
Expected: build succeeds; version prints `0.1.0`; the icns is multi-size (file noticeably larger than a single 1024 png).

- [ ] **Step 6: Commit**

```bash
git add VERSION scripts/make-app.sh
git commit -m "build: version/build-number from VERSION+git; always build multi-size icns (fixes blank Stage Manager icon)"
```

### Task B2: `scripts/install.sh` (build → /Applications → icon-cache bust)

**Files:**
- Create: `scripts/install.sh`

- [ ] **Step 1: Create `scripts/install.sh`**

```bash
#!/bin/bash
# Build OpenPhoto and install it as your stable copy in /Applications, refreshing the icon caches
# so the new icon shows immediately in Dock / Launchpad / Stage Manager. No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

DEST="/Applications/OpenPhoto.app"
echo "Installing to $DEST …"
rm -rf "$DEST"
cp -R build/OpenPhoto.app "$DEST"

# Bust LaunchServices' icon cache so Dock/Launchpad/Stage-Manager pick up the new icon.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$DEST" || true
killall Dock Finder 2>/dev/null || true

echo "Installed OpenPhoto $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")."
echo "Launch from Launchpad/Spotlight, or: open \"$DEST\""
```

- [ ] **Step 2: Make executable and run**

Run: `chmod +x scripts/install.sh && ./scripts/install.sh`
Expected: app appears in `/Applications`; Dock/Finder restart; `open /Applications/OpenPhoto.app` launches it.

- [ ] **Step 3: Verify the icon in the minimized strip** — launch, minimize the window (⌘M), and confirm the right-side/Stage-Manager thumbnail shows the OpenPhoto glyph (not a blank square).

- [ ] **Step 4: Commit**

```bash
git add scripts/install.sh
git commit -m "build: install.sh — build + install to /Applications + refresh icon caches"
```

### Task B3: `scripts/make-dmg.sh` (shareable drag-to-install DMG)

**Files:**
- Create: `scripts/make-dmg.sh`

- [ ] **Step 1: Create `scripts/make-dmg.sh`**

```bash
#!/bin/bash
# Build OpenPhoto and package it as a shareable, drag-to-Applications DMG. Uses only system tools.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh
VERSION="$(tr -d '[:space:]' < VERSION)"

STAGE="$(mktemp -d)/OpenPhoto"
mkdir -p "$STAGE"
cp -R build/OpenPhoto.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Installing OpenPhoto
--------------------
1. Drag OpenPhoto onto the Applications folder shown here.
2. The FIRST time you open it, macOS may say it "cannot verify" the app (because it isn't
   signed with a paid Apple Developer ID). This is expected.
   - Right-click (or Control-click) OpenPhoto in Applications and choose "Open", then "Open" again,
     OR open System Settings > Privacy & Security, scroll down, and click "Open Anyway".
   - You only do this once. Future updates install silently.
3. On first launch, choose your photo folder (e.g. your Pictures folder).

Your photos are never modified or moved. Delete OpenPhoto anytime — your files are untouched.
TXT

DMG="build/OpenPhoto-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "OpenPhoto ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "Built $DMG"
```

- [ ] **Step 2: Make executable and run**

Run: `chmod +x scripts/make-dmg.sh && ./scripts/make-dmg.sh`
Expected: `build/OpenPhoto-0.1.0.dmg` is created.

- [ ] **Step 3: Verify** — `open build/OpenPhoto-0.1.0.dmg`; the mounted volume shows OpenPhoto.app, an Applications symlink, and the READ ME. Drag-install works.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-dmg.sh
git commit -m "build: make-dmg.sh — shareable drag-to-Applications DMG with first-run instructions"
```

---

## Slice C — Self-update (Sparkle)

> **Execute C0 first and stop at its verify gate.** Embedding Sparkle's framework into a hand-assembled `.app` is the riskiest step; confirm the app launches and "Check for Updates…" works before building release automation.

### Task C0 (spike): add Sparkle, embed the framework, get the app to launch with a working updater

**Files:**
- Modify: `Package.swift`, `Sources/OpenPhotoApp/OpenPhotoApp.swift`, `scripts/make-app.sh`

- [ ] **Step 1: Add the Sparkle dependency in `Package.swift`**

In `dependencies:` add:
```swift
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
```
In the `OpenPhotoApp` target's `dependencies:` change to:
```swift
            dependencies: ["OpenPhotoCore", .product(name: "Sparkle", package: "Sparkle")]
```

- [ ] **Step 2: Resolve and locate the framework**

Run: `swift build -c release`
Run: `find .build -name 'Sparkle.framework' -type d`
Expected: prints a path like `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`. **Record it** — Step 5 copies from there.

- [ ] **Step 3: Wire the updater in `OpenPhotoApp.swift`.** Add `import Sparkle` at the top, an updater controller on the `App`, and a "Check for Updates…" command:

```swift
import Sparkle
```
Add the controller property to `struct OpenPhotoApp` (after `@State private var state`):
```swift
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```
Add a commands block (after the existing `.commands { … }` closes, chain another, or add inside it) — add a CommandGroup:
```swift
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
            }
```

- [ ] **Step 4: Add Sparkle Info.plist keys in `make-app.sh`.** Inside the Info.plist heredoc (before `</dict>`), add:

```
    <key>SUFeedURL</key><string>https://jude-sph.github.io/OpenPhoto/appcast.xml</string>
    <key>SUPublicEDKey</key><string>__SUPUBLICEDKEY__</string>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
```
After the `sed` token substitution from Task B1 Step 3, add another substitution that reads the public key from a committed file (created in C1):
```bash
SUKEY="$(tr -d '[:space:]' < scripts/sparkle_public_key.txt 2>/dev/null || true)"
sed -i '' "s|__SUPUBLICEDKEY__|${SUKEY}|" "$APP/Contents/Info.plist"
```
(Until C1 generates the key, `__SUPUBLICEDKEY__` becomes empty — Sparkle still launches; updates just can't verify yet. That's fine for the C0 launch test.)

- [ ] **Step 5: Embed + sign the framework in `make-app.sh`.** Immediately **before** the final `codesign --force --sign - "$APP"` line, insert:

```bash
# Embed Sparkle.framework (and its XPC helpers, which live inside it) into the bundle.
SPARKLE_FW="$(find .build -name 'Sparkle.framework' -type d | head -1)"
if [[ -n "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  # Ensure the executable can find @rpath/Sparkle.framework under Contents/Frameworks.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/OpenPhoto" 2>/dev/null || true
  # Sign nested XPC services + the framework (ad-hoc), inside-out, before signing the app.
  find "$APP/Contents/Frameworks/Sparkle.framework" -name '*.xpc' -print0 \
    | while IFS= read -r -d '' xpc; do codesign --force --sign - "$xpc"; done
  codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
  echo "Embedded Sparkle.framework"
else
  echo "warning: Sparkle.framework not found in .build — run 'swift build' first"
fi
```

- [ ] **Step 6: Build and launch — the verify gate**

Run: `./scripts/install.sh && open /Applications/OpenPhoto.app`
Expected: app launches with **no dyld crash** (a missing/mis-rpath framework shows as an immediate crash referencing `Sparkle`). Open the app menu → **Check for Updates…** → Sparkle shows a dialog (it will report an error/no-feed until the appcast exists — that's fine; the point is the updater is alive and the framework is loaded).

If it crashes on launch: re-check the `find` path from Step 2, confirm `Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle` exists, and that `otool -l build/OpenPhoto.app/Contents/MacOS/OpenPhoto | grep -A2 LC_RPATH` includes `@executable_path/../Frameworks`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/OpenPhotoApp/OpenPhotoApp.swift scripts/make-app.sh
git commit -m "feat(update): integrate Sparkle — updater controller, Check for Updates, embedded framework"
```

### Task C1: Generate the EdDSA signing key (one-time)

**Files:**
- Create: `scripts/sparkle_public_key.txt` (public key — safe to commit)

- [ ] **Step 1: Build Sparkle's tools and generate the key**

Run: `find .build -path '*/Sparkle/bin/generate_keys' -o -name 'generate_keys' -type f | head -1`
Run that `generate_keys` binary. It stores the **private** key in your login Keychain and prints the **public** key.
Expected: prints `<dict>… SUPublicEDKey …</dict>` containing a base64 public key.

- [ ] **Step 2: Save the PUBLIC key (only) to a committed file**

Write the printed base64 public key (the value only) into `scripts/sparkle_public_key.txt` (single line, no whitespace).

- [ ] **Step 3: Re-build so the key lands in Info.plist**

Run: `./scripts/make-app.sh && /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/OpenPhoto.app/Contents/Info.plist`
Expected: prints your public key (non-empty).

- [ ] **Step 4: Commit (public key only — the private key NEVER leaves your Keychain)**

```bash
git add scripts/sparkle_public_key.txt
git commit -m "build: commit Sparkle EdDSA public key (private key stays in Keychain only)"
```

### Task C2: `scripts/release.sh` (build → zip/dmg → sign appcast → GitHub Release → publish appcast)

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1: Create `scripts/release.sh`**

```bash
#!/bin/bash
# Cut and publish a new OpenPhoto release: build the app + DMG, zip it, sign + regenerate the
# Sparkle appcast, create a GitHub Release with the artifacts, and publish the appcast to GitHub
# Pages. Requires: `gh` (authenticated), Sparkle's generate_appcast, the EdDSA private key in your
# Keychain. See docs/RELEASING.md for one-time setup. Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
echo "Releasing ${TAG} …"

# 1. Build artifacts.
./scripts/make-dmg.sh                       # build/OpenPhoto-<v>.dmg (also builds the .app)
RELDIR="build/release-archives"
rm -rf "$RELDIR"; mkdir -p "$RELDIR"
ditto -c -k --keepParent build/OpenPhoto.app "$RELDIR/OpenPhoto-${VERSION}.zip"
cp "build/OpenPhoto-${VERSION}.dmg" "$RELDIR/"

# 2. Sign + (re)generate the appcast. generate_appcast reads the private key from the Keychain and
#    writes appcast.xml into RELDIR, pointing downloads at the GitHub Releases asset URLs.
GENAPPCAST="$(find .build -path '*/Sparkle/bin/generate_appcast' -o -name generate_appcast -type f | head -1)"
"$GENAPPCAST" \
  --download-url-prefix "https://github.com/jude-sph/OpenPhoto/releases/download/${TAG}/" \
  "$RELDIR"

# 3. Create the GitHub Release with the zip + dmg.
gh release create "$TAG" \
  "$RELDIR/OpenPhoto-${VERSION}.zip" "$RELDIR/OpenPhoto-${VERSION}.dmg" \
  --title "OpenPhoto ${VERSION}" --notes "OpenPhoto ${VERSION}"

# 4. Publish appcast.xml to the gh-pages branch (served at the SUFeedURL).
git fetch origin gh-pages 2>/dev/null || git branch gh-pages
WORKTREE="$(mktemp -d)"
git worktree add "$WORKTREE" gh-pages
cp "$RELDIR/appcast.xml" "$WORKTREE/appcast.xml"
( cd "$WORKTREE" && git add appcast.xml \
    && git commit -m "appcast: OpenPhoto ${VERSION}" && git push origin gh-pages )
git worktree remove "$WORKTREE"

echo "Released ${TAG}. Verify the live appcast in ~1 min:"
echo "  curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml | head"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/release.sh`
(Do not run it yet — running it publishes a real release. It runs for real in Task C3 after Pages is configured.)

- [ ] **Step 3: Commit**

```bash
git add scripts/release.sh
git commit -m "build: release.sh — build, sign appcast, GitHub Release, publish to gh-pages"
```

### Task C3: Configure GitHub Pages + cut the first real release + verify auto-update

**Files:** none (operational)

- [ ] **Step 1: Create the gh-pages branch with a placeholder and enable Pages**

Run:
```bash
git worktree add /tmp/op-ghpages -b gh-pages 2>/dev/null || git worktree add /tmp/op-ghpages gh-pages
printf '<?xml version="1.0"?>\n<rss version="2.0"></rss>\n' > /tmp/op-ghpages/appcast.xml
( cd /tmp/op-ghpages && git add appcast.xml && git commit -m "chore: seed gh-pages appcast" && git push -u origin gh-pages )
git worktree remove /tmp/op-ghpages
```
Then in GitHub repo Settings → Pages, set Source = `gh-pages` branch, `/ (root)`. Confirm `https://jude-sph.github.io/OpenPhoto/appcast.xml` serves the placeholder.

- [ ] **Step 2: Cut the first release**

Run: `./scripts/release.sh`
Expected: a `v0.1.0` GitHub Release with the zip + dmg, and an updated `appcast.xml` on gh-pages.

- [ ] **Step 3: Verify the end-to-end update on a clean machine/VM (or simulate)**

- Install `v0.1.0` from the DMG. Quit.
- Bump `VERSION` to `0.1.1`, commit, `./scripts/release.sh` again.
- Re-launch the installed `0.1.0`; within the update interval (or via **Check for Updates…**) Sparkle should offer `0.1.1`, install on one click, and relaunch **with no second "Open Anyway"** (Sparkle strips quarantine).

- [ ] **Step 4: Commit the version bump used for the test**

```bash
git add VERSION
git commit -m "release: 0.1.1"
```

### Task C4: Documentation — RELEASING, DISTRIBUTING, README, manual checklist

**Files:**
- Create: `docs/RELEASING.md`, `docs/DISTRIBUTING.md`
- Modify: `README.md`, `docs/manual-test-checklist.md`

- [ ] **Step 1: Write `docs/RELEASING.md`** covering, in order:
  - **One-time setup:** install `gh` and authenticate; build Sparkle tools (`swift build`); run `generate_keys` (private key → Keychain, public key → `scripts/sparkle_public_key.txt`, already committed); enable GitHub Pages on `gh-pages`; the `SUFeedURL` is `https://jude-sph.github.io/OpenPhoto/appcast.xml`.
  - **Cut a release:** bump `VERSION`, commit, run `./scripts/release.sh`; what each step produces; verify the live appcast with the `curl` one-liner.
  - **NEVER commit the EdDSA private key.** It lives only in the login Keychain. If lost, you must generate a new key, ship a new public key, and existing users must reinstall manually (updates can't be verified across a key change).
  - **GitHub Actions (future, optional):** sketch a `release.yml` on `v*` tag push using a `macos` runner, with the private key as an encrypted repo secret fed to `generate_appcast` — realizing "push a tag → everyone updates" with no manual steps.
  - **Troubleshooting:** appcast not picked up (Pages latency; check `curl`), signature mismatch (wrong key/Keychain), build number not increasing (`git rev-list --count HEAD` must only grow — don't rewrite history), framework load crash (re-check the embed/rpath steps in `make-app.sh`).

- [ ] **Step 2: Write `docs/DISTRIBUTING.md`** covering:
  - **What to send:** `build/OpenPhoto-<version>.dmg` only. **Never** send `scripts/sparkle_public_key.txt`’s private counterpart (it isn't in the repo anyway) or your Keychain.
  - **How the recipient installs:** open the DMG, drag to Applications; the one-time Gatekeeper step (right-click → Open, or System Settings → Privacy & Security → "Open Anyway"); the `xattr -dr com.apple.quarantine /Applications/OpenPhoto.app` fast path; the USB-stick alternative (no quarantine).
  - **First launch:** choose your photo folder (your Pictures folder); not the `Photos Library` package.
  - **Updates:** they’ll get a one-click "Update available" prompt automatically; no reinstall, no second Gatekeeper prompt.

- [ ] **Step 3: Add an "Install / Build / Release" section to `README.md`** linking to both docs and listing the three scripts (`install.sh` = your own stable copy; `make-dmg.sh` = a shareable DMG; `release.sh` = publish an update for everyone).

- [ ] **Step 4: Append to `docs/manual-test-checklist.md`** the A/B/C smoke items from the spec's Testing section (root switch live; Welcome fallback on missing root; icon in Dock + minimized strip; DMG drag-install; older build sees + installs the update with no second Open Anyway).

- [ ] **Step 5: Commit**

```bash
git add docs/RELEASING.md docs/DISTRIBUTING.md README.md docs/manual-test-checklist.md
git commit -m "docs: RELEASING + DISTRIBUTING guides, README install section, manual-test items"
```

---

## Self-Review

**Spec coverage:**
- A — single-root config in Settings + Welcome + switch semantics → Tasks A1–A5. ✓
- B — VERSION, install to /Applications, DMG, icon fix → Tasks B1–B3. ✓
- C — Sparkle, EdDSA keys, GitHub Pages appcast, release automation, ad-hoc quarantine-strip → Tasks C0–C3. ✓
- Documentation deliverables (RELEASING.md, DISTRIBUTING.md, README, checklist) → Task C4. ✓
- Auto-update aggressiveness (Sparkle default ask-once + ~daily + manual) → C0 Step 3/4 (`SUScheduledCheckInterval`, no `SUEnableAutomaticChecks` so Sparkle prompts once). ✓
- Format-doc impact = none → confirmed in spec; no `docs/format/` task needed. ✓

**Placeholder scan:** All code/commands are concrete. The only intentional runtime-filled token is `SUPublicEDKey`, generated in C1 and injected by `make-app.sh`; called out explicitly. No TBD/TODO.

**Type/name consistency:** `purgeLocalVault(id:)`, `closeLibrary()`, `changeRoot(to:)`, `closeLibraryAndForgetRoot()`, `configuredRoot`, `DeviceWatcher.stop()` are defined once and referenced consistently. `AssetRecord`/`InstanceRecord`/`VaultPresenceEntry` constructors match `Records.swift` and existing tests. `Vault.descriptor.role == .local` flagged in A3 Step 4 to verify the enum case name at execution.

**Risks flagged inline:** Sparkle framework embedding (C0 verify gate before automation), icon-cache stubbornness (lsregister + killall), GitHub Pages latency (curl-verify step), build-number monotonicity.

**Execution order:** A (immediate value: point at ~/Pictures) → B (installable app + icon) → C0 verify gate → C1–C4. Each task commits independently.
