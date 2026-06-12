# OpenPhoto — Configurable Root, Packaging & Self-Update

**Status:** approved design (2026-06-12)
**Supersedes/extends:** `2026-06-07-openphoto-design.md` (distribution & first-run sections)

## Purpose

Turn OpenPhoto from a dev build that boots into a hardcoded test folder into a
real, installable, shareable macOS app that family & friends can run and that
updates itself. Three independently-shippable slices:

- **A — Configurable library root (in-app):** point OpenPhoto at any folder
  (e.g. `~/Pictures`) and change it later from Settings.
- **B — Packaging, install & icon:** produce a versioned, drag-to-install DMG;
  install a stable copy to `/Applications`; fix the blank app icon.
- **C — Self-update (Sparkle):** the app checks GitHub for new releases and
  installs them with one click — no toolchain on the recipient's machine.

Tile-grid optimization (the last open Phase 5.5 item) is **out of scope** and
gets its own brainstorm → spec → plan cycle afterward.

## Decisions already made

- **Signing: ad-hoc only** (`codesign --sign -`). No Apple Developer ID, no
  notarization. Recipients accept a one-time Gatekeeper "Open Anyway" on first
  launch (or receive the app on a USB stick, which carries no quarantine flag).
- **One library root, not many.** The user configures a single local folder.
  (`LibraryService` keeps its internal `[Vault]` array — drives depend on it —
  but the app only ever configures one *local* root.)
- **Self-update tracks releases/tags, not raw commits.** The developer decides
  when to cut a release; users never receive work-in-progress commits.
- **Auto-update aggressiveness:** Sparkle's standard flow — ask once on first
  launch whether to enable automatic checks, then a quiet ~daily background
  check that only prompts when a new release exists. A manual
  "Check for Updates…" menu item is always available.

## Non-goals

- Multiple/managed library roots, or a roots add/remove UI.
- Notarization or a paid Developer ID (can be layered on later with no rework).
- Self-update by pulling source and rebuilding on the user's machine
  (infeasible — recipients have no Swift/Xcode toolchain; a failed build would
  brick the app with no recovery UI).
- Tile-grid rendering optimization.
- Any change to the on-disk vault format (see "Format-doc impact").

---

## Slice A — Configurable library root (in-app)

### Current state

- Roots persist in `UserDefaults` under `libraryRootPaths` (an array).
- `WelcomeView` already chooses folders via `NSOpenPanel` (defaulting to
  `~/Pictures`) and calls `AppState.openLibrary(roots:)`.
- `OpenPhotoApp.swift` shows `WelcomeView` when `state.library == nil`, else the
  main UI; on launch it opens the library if `configuredRoots` is non-empty.
- The app is **not sandboxed** (no entitlements; plain paths, no
  security-scoped bookmarks).
- The catalog is a single global `~/Library/Application Support/OpenPhoto/
  catalog.sqlite`; vaults are *registered* into it (`registerVault`), and a
  vault can be removed with `unregisterVault` (deletes the vault row + its
  `vault_presence`). Local roots and external drives share this catalog.

The only real gap: there is no way to **change** the root after first run, and
the saved default currently points at the repo's `fixtures-library`.

### Design

**Settings — Library Location row.** Add a "Library" section to `SettingsView`
with:
- the current root path (monospaced, truncating middle), and
- a **Change…** button → `NSOpenPanel` (single folder, defaults to
  `~/Pictures`).
- a secondary **Close Library** action that returns to the Welcome screen
  (sets `library = nil`).

No list, no add/remove — exactly one root at a time.

**Menu command.** `File → Library…` opens Settings focused on the Library
section (or, minimally, opens Settings — focusing the section is a nicety).

**Welcome screen.** Simplify `WelcomeView` to choose a *single* folder:
"Choose your photo folder" → one selection → "Open library". Drop the
multi-select list UI.

**Switch semantics (the important part).** Changing the root from A to B:
1. Confirm with the user (one alert: "Switch OpenPhoto to <B>? Photos from <A>
   will be removed from OpenPhoto's views. Your files and any edits are not
   touched.").
2. Tear down the running library (watchers, device watcher callbacks).
3. **Unregister the old local vault and purge its catalog rows** (instances and
   derived data) so its photos leave every view.
4. Open/register the new vault at B, persist `libraryRootPaths = [B]`, scan it
   in live (no app restart).

**Re-entrancy.** `openLibrary(roots:)` currently assumes a cold first open (it
starts watchers and `deviceWatcher.start()`). Refactor it so it can be called
again on an already-running app: stop/reset the previous watchers and clear the
old `library` before rebuilding. Extract a `closeLibrary()` (teardown) used by
both "switch" and "Close Library".

**Why switching is safe by construction.** Human-authored metadata lives in XMP
sidecars on disk (Hard Invariant #2); the catalog is purely rebuildable
machine-derived data. So purging the old vault's catalog rows loses *nothing*
authored — re-adding that folder later rescans the sidecars and recomputes
faces/embeddings. This must be stated in the confirm dialog and the docs.

**Privacy (TCC).** Reading `~/Pictures` (the folder) may trigger a one-time
macOS privacy prompt on first access; the user clicks Allow. No entitlement or
Info.plist key is required for a non-sandboxed app. Note in docs: point at the
`~/Pictures` *folder*, never the `Photos Library.photoslibrary` package (Apple's
internal database).

### Edge cases

- **Saved root no longer exists** (folder deleted/renamed/unmounted): on launch,
  if the configured root is missing, fall back to the Welcome screen rather than
  failing to open. (Don't purge the catalog automatically — the folder may just
  be a temporarily-unplugged drive.)
- **Choosing the same folder again:** no-op (don't purge + rescan needlessly).
- **Choosing a parent/child of the current root:** treated as a normal switch
  (purge old, scan new). No special nesting logic.

### Rollout for the current machine

After this ships, the developer opens Settings → Library → Change… → `~/Pictures`
(or runs `defaults delete dev.jude.openphoto libraryRootPaths` once to land on
the Welcome screen). No migration code needed.

---

## Slice B — Packaging, install & icon

### Version as single source of truth

- Add a top-level `VERSION` file (e.g. `0.1.0`).
- `make-app.sh` reads `VERSION` and injects it into `Info.plist`
  `CFBundleShortVersionString`. `CFBundleVersion` (build number) = a
  monotonically increasing integer, derived from `git rev-list --count HEAD`
  (always increases, required by Sparkle to compare builds).
- Remove the hardcoded `0.1.0` from `make-app.sh`.

### Scripts

Keep `scripts/make-app.sh` (assembles `build/OpenPhoto.app`, ad-hoc signs). Add:

- **`scripts/install.sh`** — your "stable in Launchpad" path:
  `make-app.sh` → copy `build/OpenPhoto.app` to `/Applications/OpenPhoto.app`
  (replacing any old copy) → bust the icon cache → optionally relaunch.
- **`scripts/make-dmg.sh`** — the shareable artifact:
  build → stage `OpenPhoto.app` + an `/Applications` symlink in a temp folder →
  `hdiutil create` a compressed `OpenPhoto-<VERSION>.dmg` (drag-to-install
  layout). `hdiutil` is already present; no third-party `create-dmg` dependency.

### Icon fix (the blank-icon bug)

**Symptom:** the minimized-window thumbnail (Stage Manager / right-side strip)
shows a blank white rounded square instead of the app glyph; the Dock icon looks
fine.

**Likely cause:** `make-app.sh` prefers the prebuilt
`IconKitchen-Output/macos/AppIcon.icns`, which appears to carry essentially only
the 1024px representation. Surfaces that request a *small* named rep (the
minimized-strip badge) find no matching size and fall back to the generic
placeholder.

**Fix:**
1. **Always regenerate a full multi-size `.icns`** from `AppIcon1024.png`
   covering 16, 32, 128, 256, 512 at @1x and @2x (→ up to 1024) via
   `sips` + `iconutil` (the script already has this code path in its fallback
   branch — make it the *primary* path; stop trusting the single-rep prebuilt
   `.icns`).
2. **Bust LaunchServices' icon cache** on install: `touch` the installed
   bundle and `killall Dock Finder` (and, if needed,
   `lsregister -f /Applications/OpenPhoto.app`) so Dock, Stage Manager, and the
   minimized strip all refresh.
3. **Verify** by minimizing the window and confirming the strip badge shows the
   glyph.

### Quarantine / first-run guidance

The DMG includes a short `READ ME FIRST.txt` (or the docs cover it): first launch
needs **right-click → Open**, or **System Settings → Privacy & Security →
"Open Anyway"** (the right-click trick is removed on macOS 15+). Optional fast
path: `xattr -dr com.apple.quarantine /Applications/OpenPhoto.app`. USB-stick
delivery avoids the prompt entirely (no quarantine flag).

---

## Slice C — Self-update (Sparkle)

### Components

- **Sparkle** added as an SPM dependency on the `OpenPhotoApp` target
  (`github.com/sparkle-project/Sparkle`, 2.x).
- **`SPUStandardUpdaterController`** instantiated at app start (started
  automatically). A **"Check for Updates…"** menu item bound to its
  `checkForUpdates` action. Automatic background checks enabled per the
  "standard flow" decision above.
- **EdDSA key pair** (Sparkle's `generate_keys`): the **public** key goes in
  `Info.plist` as `SUPublicEDKey`; the **private** key lives only in the
  developer's login Keychain (Sparkle stores it there) and **is never
  committed**. Each release archive is signed with it. This is Sparkle's own
  authenticity check — independent of Apple code signing — so ad-hoc is fine.
- **`Info.plist` keys:** `SUFeedURL` (appcast URL, see hosting), `SUPublicEDKey`,
  `SUEnableAutomaticChecks` (true), `SUScheduledCheckInterval` (~86400).

### Hosting (GitHub)

- Each release uploads `OpenPhoto-<VERSION>.zip` (Sparkle installs from a zipped
  `.app`) to **GitHub Releases** on `jude-sph/OpenPhoto`.
- Sparkle's **`generate_appcast`** tool scans a local folder of release archives
  and produces a signed `appcast.xml` (EdDSA signatures + versions + URLs).
- `appcast.xml` is published via **GitHub Pages** for the repo (a stable URL),
  and `SUFeedURL` points at it.

### Release granularity & ad-hoc payoff

- Users only ever see versions the developer explicitly **releases** (a tag +
  GitHub Release), never raw commits.
- **Sparkle strips the quarantine attribute** from the app it installs, so after
  the single manual first install, every subsequent update lands silently — even
  ad-hoc.

### Release automation

- **`scripts/release.sh`** (the documented, repeatable path) does, in order:
  1. read/confirm `VERSION` (or bump it),
  2. `make-app.sh` → `make-dmg.sh` → zip the `.app`,
  3. `generate_appcast` over the archives folder (signs with the Keychain key),
  4. `gh release create v<VERSION>` uploading the `.zip` and `.dmg`,
  5. publish the updated `appcast.xml` to the GitHub Pages source.
- **Stretch (designed, optional, not required for first ship):** a GitHub Actions
  workflow triggered on `v*` tag push that runs the same steps on a macOS runner,
  with the EdDSA private key stored as an encrypted repo secret — realizing
  "push a tag → everyone auto-updates" with zero manual steps. Documented in
  `RELEASING.md` as the future path; first releases are cut locally.

---

## Documentation deliverables (first-class)

Per the project's documentation discipline, the release/distribution machinery
must be **thoroughly documented for future developers** — someone who has never
seen this repo should be able to cut a release or hand the app to a friend by
following the docs alone.

- **`docs/RELEASING.md`** — end-to-end "how to publish a new version":
  - one-time setup (generating the EdDSA keys, where the private key lives, the
    GitHub Pages appcast URL, installing `gh`/Sparkle tools);
  - the per-release checklist (bump `VERSION`, run `scripts/release.sh`, verify
    the appcast updated, smoke-test that an installed older build sees and
    installs the update);
  - **what must never be committed** (the EdDSA private key);
  - the GitHub Actions stretch path;
  - troubleshooting (appcast not picked up, signature mismatch, build-number not
    increasing).
- **`docs/DISTRIBUTING.md`** — "what to share and how to install":
  - which file to send (the `OpenPhoto-<VERSION>.dmg`) and which **not** to send;
  - recipient install steps (drag to Applications) + the one-time Gatekeeper
    "Open Anyway" walkthrough (with screenshots-in-words) and the `xattr`
    one-liner / USB-stick alternative;
  - how updates work for the recipient (the one-click Sparkle prompt) so they
    aren't surprised.
- **`README.md`** — a short "Install / Build / Release" section linking to the
  two docs above.
- **`scripts/*.sh`** — each carries a header comment explaining what it does and
  its prerequisites (the scripts are themselves documentation).

### Format-doc impact

**None.** No on-disk vault/catalog/sidecar format changes. Switching the root
purges *rebuildable* catalog rows only; the vault format spec
(`docs/format/vault-format-v1.md`) is unaffected. The appcast, EdDSA keys, and
DMG are distribution artifacts documented in `RELEASING.md`/`DISTRIBUTING.md`,
not in `docs/format/`.

---

## Build order

1. **Slice A** — configurable single root (Settings row + simplified Welcome +
   re-entrant `openLibrary`/`closeLibrary` + switch-purge semantics). Lets the
   developer immediately point at `~/Pictures`.
2. **Slice B** — `VERSION`, `install.sh`, `make-dmg.sh`, icon regeneration +
   cache bust. Produces a real installable/shareable app and fixes the icon.
3. **Slice C** — Sparkle integration, EdDSA keys, appcast on GitHub Pages,
   `release.sh`, and the documentation deliverables.

Each slice is independently shippable; B's versioning feeds C's appcast.

## Testing

Unit/automated where it makes sense (root switch teardown logic, version
injection); the rest is manual smoke (the app is GUI/packaging heavy). Add to
`docs/manual-test-checklist.md`:

- **A:** first run shows Welcome; choose `~/Pictures`; switch root via Settings
  and confirm old photos leave + new appear without restart; relaunch with a
  missing root falls back to Welcome; authored metadata survives a switch+switch
  back.
- **B:** `install.sh` puts a launchable app in `/Applications`; the icon shows
  in Dock **and** the minimized/Stage-Manager strip; the DMG mounts and
  drag-installs.
- **C:** an installed older build detects a newer release, shows the prompt, and
  updates silently on relaunch (no second "Open Anyway"); "Check for Updates…"
  works on demand; a tampered archive fails signature verification.

## Risks

- **Icon cache stubbornness:** LaunchServices can cache aggressively; the
  cache-bust may need `lsregister -f` and occasionally a logout. Documented.
- **Sparkle + ad-hoc nuance:** verify on a clean machine/VM that the
  quarantine-strip-on-update behavior actually yields a silent second launch.
- **GitHub Pages appcast latency:** Pages can take a minute to publish; the
  release checklist includes a "wait + verify the live appcast" step.
- **Build-number monotonicity:** `git rev-list --count HEAD` must only ever grow;
  note that history rewrites would break update comparison.
