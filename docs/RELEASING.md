# Releasing OpenPhoto

This document covers everything a developer needs to publish a new version of OpenPhoto — from one-time setup through the per-release checklist to advanced automation. A developer who has never touched this repo should be able to follow this document alone and cut a working release.

---

## One-time setup

These steps are performed **once per developer machine**. Skip them if you've already done them.

### 1. Install and authenticate `gh`

`gh` is the GitHub CLI used by `release.sh` to create GitHub Releases.

```bash
brew install gh
gh auth login
```

Choose HTTPS and follow the browser-based OAuth flow. Verify with:

```bash
gh auth status
```

### 2. Build Sparkle's tools

Sparkle's `generate_keys` and `generate_appcast` binaries are built from source by SwiftPM; they are not committed to the repo. Run a release build once so they land in `.build`:

```bash
swift build -c release
```

Confirm the tools exist:

```bash
find .build -name 'generate_keys' -type f
find .build -name 'generate_appcast' -type f
```

Both should print a path under `.build/artifacts/sparkle/Sparkle/…/bin/`.

### 3. Generate the EdDSA signing key

> **CRITICAL: The private key must NEVER be committed to the repository or stored anywhere outside your login Keychain. See the warning section below.**

Run Sparkle's `generate_keys` binary (the path is the one found in Step 2):

```bash
"$(find .build -name 'generate_keys' -type f | head -1)"
```

`generate_keys` will:
- Store the **private** key securely in your macOS login Keychain (item name `Sparkle`).
- Print the **public** key as a base64 string (44 characters ending in `=`).

Copy the printed public key and write it to the committed file:

```bash
echo -n 'YOUR_PUBLIC_KEY_HERE' > scripts/sparkle_public_key.txt
```

Verify the file contains exactly the key with no extra whitespace:

```bash
cat scripts/sparkle_public_key.txt
```

Then rebuild to confirm the key lands in `Info.plist`:

```bash
./scripts/make-app.sh
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/OpenPhoto.app/Contents/Info.plist
```

The printed value must match the key in `scripts/sparkle_public_key.txt`.

Commit the public key:

```bash
git add scripts/sparkle_public_key.txt
git commit -m "build: commit Sparkle EdDSA public key (private key stays in Keychain only)"
```

> **Note:** `make-app.sh` hard-fails if `scripts/sparkle_public_key.txt` is missing or empty. Generating the key is a prerequisite for any packaging — do this before trying to build a distributable app.

### 4. Enable GitHub Pages

The appcast (`appcast.xml`) is served from the `gh-pages` branch of the `jude-sph/OpenPhoto` repository.

If the `gh-pages` branch does not yet exist, seed it with a placeholder:

```bash
git worktree add /tmp/op-ghpages -b gh-pages
printf '<?xml version="1.0"?>\n<rss version="2.0"></rss>\n' > /tmp/op-ghpages/appcast.xml
( cd /tmp/op-ghpages && git add appcast.xml \
    && git commit -m "chore: seed gh-pages appcast" \
    && git push -u origin gh-pages )
git worktree remove /tmp/op-ghpages
```

Then in the GitHub repository settings:

1. Go to **Settings → Pages**.
2. Under **Source**, choose **Deploy from a branch**.
3. Select the `gh-pages` branch and the `/ (root)` folder.
4. Click **Save**.

Wait about a minute for Pages to build, then confirm the appcast URL is live:

```bash
curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml
```

This URL is already hardcoded as `SUFeedURL` in `Info.plist` (injected by `make-app.sh`). Do not change it without also updating `make-app.sh`.

---

## Per-release checklist

Follow these steps every time you publish a new version.

### 1. Bump the version

Edit `VERSION` at the repo root (e.g., change `0.1.0` to `0.1.1`):

```bash
echo '0.1.1' > VERSION
```

Commit the bump:

```bash
git add VERSION
git commit -m "release: 0.1.1"
```

The build number is derived automatically from `git rev-list --count HEAD` (always increases with each commit — see Troubleshooting if this seems to go backwards).

### 2. Run `release.sh`

```bash
./scripts/release.sh
```

The script does the following in order:

1. **Reads `VERSION`** to derive the release tag (e.g., `v0.1.1`).
2. **Calls `make-dmg.sh`**, which calls `make-app.sh` (builds the release binary, injects the version + build number + Sparkle keys into `Info.plist`, builds the multi-size icon, embeds `Sparkle.framework`, ad-hoc signs the bundle), then packages it as `build/OpenPhoto-<version>.dmg`.
3. **Zips the `.app`** with `ditto` into `build/release-archives/OpenPhoto-<version>.zip` — this is what Sparkle downloads and installs.
4. **Copies the DMG** into `build/release-archives/`.
5. **Runs `generate_appcast`** over the `build/release-archives/` folder. `generate_appcast` reads the EdDSA private key from your Keychain, signs each archive, and writes `appcast.xml` into `build/release-archives/`. The `--download-url-prefix` flag points the URLs at the GitHub Releases asset links.
6. **Creates a GitHub Release** (`gh release create`) named `v<VERSION>`, uploading both the `.zip` and the `.dmg` as release assets.
7. **Publishes `appcast.xml`** to the `gh-pages` branch via a temporary `git worktree`, then pushes it to `origin`. This is the file that running apps download to check for updates.

### 3. Verify the live appcast

GitHub Pages takes up to a minute to reflect a push. Then:

```bash
curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml | head -40
```

You should see an `<item>` element whose `<title>` is the new version and whose `<sparkle:shortVersionString>` and `<sparkle:version>` match. If the appcast looks stale, wait another minute and retry.

### 4. Smoke-test the update flow

Install the **previous** version's DMG on a machine, launch the app, and use **App menu → Check for Updates…** to confirm it detects the new version, downloads it, and relaunches — with no second Gatekeeper prompt.

---

## NEVER commit the EdDSA private key

The EdDSA private key lives **only** in your macOS login Keychain under the item name `Sparkle`. It is never written to disk as a file and must never be committed to the repository.

- The `.gitignore` does not need to list it because it was never created as a file.
- If you ever accidentally generate a key file by hand, delete it immediately and verify it is not staged: `git status`.

**What happens if the private key is lost:**

Each `appcast.xml` entry carries an EdDSA signature. Running apps verify the downloaded archive against the public key in `Info.plist` before installing. If the private key is lost (e.g., Keychain wiped, migrated to a new machine without a Keychain backup):

1. You cannot sign new appcast entries — `generate_appcast` will fail or produce entries with invalid signatures that all running apps will reject.
2. You must generate a **new** key pair with `generate_keys`.
3. Update `scripts/sparkle_public_key.txt` with the new public key, rebuild, and cut a release with the new key in `Info.plist`.
4. **Existing users cannot auto-update across a key change** — their installed app has the old public key and will reject the new signatures. They must download and manually install the new DMG (one-time, with the standard Gatekeeper "Open Anyway" step). Announce this in the release notes.

**Key recovery on a new machine:**

Use macOS Keychain Access (or `security find-generic-password -s 'Sparkle'`) to export the private key before migrating machines. If no backup exists, treat the key as lost (above).

---

## GitHub Actions (future / optional)

The local `scripts/release.sh` workflow is the documented first-ship path. As an optional stretch, the release can be automated on a macOS GitHub Actions runner so that pushing a `v*` tag triggers a release with zero manual steps.

Sketch of `release.yml` (`.github/workflows/release.yml`):

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0       # git rev-list --count HEAD needs full history

      - name: Build release artifacts
        run: |
          ./scripts/make-dmg.sh
          VERSION="$(tr -d '[:space:]' < VERSION)"
          mkdir -p build/release-archives
          ditto -c -k --keepParent build/OpenPhoto.app \
            "build/release-archives/OpenPhoto-${VERSION}.zip"
          cp "build/OpenPhoto-${VERSION}.dmg" build/release-archives/

      - name: Generate appcast
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          # Write the private key to a temp file so generate_appcast can read it
          KEYFILE="$(mktemp)"
          echo "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"
          VERSION="$(tr -d '[:space:]' < VERSION)"
          TAG="v${VERSION}"
          GENAPPCAST="$(find .build -name generate_appcast -type f | head -1)"
          "$GENAPPCAST" \
            --ed-key-file "$KEYFILE" \
            --download-url-prefix \
              "https://github.com/jude-sph/OpenPhoto/releases/download/${TAG}/" \
            build/release-archives
          rm -f "$KEYFILE"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="$(tr -d '[:space:]' < VERSION)"
          gh release create "v${VERSION}" \
            "build/release-archives/OpenPhoto-${VERSION}.zip" \
            "build/release-archives/OpenPhoto-${VERSION}.dmg" \
            --title "OpenPhoto ${VERSION}" --notes "OpenPhoto ${VERSION}"

      - name: Publish appcast to gh-pages
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git fetch origin gh-pages
          git worktree add /tmp/ghpages gh-pages
          cp build/release-archives/appcast.xml /tmp/ghpages/appcast.xml
          VERSION="$(tr -d '[:space:]' < VERSION)"
          ( cd /tmp/ghpages \
              && git add appcast.xml \
              && git commit -m "appcast: OpenPhoto ${VERSION}" \
              && git push origin gh-pages )
          git worktree remove /tmp/ghpages
```

To enable this:

1. Export your Sparkle private key (from Keychain: `security find-generic-password -s 'Sparkle' -w`) and add it as an encrypted repo secret named `SPARKLE_PRIVATE_KEY` in **Settings → Secrets and variables → Actions**.
2. Commit the `release.yml` file above.
3. Push a `v*` tag (e.g., `git tag v0.1.2 && git push origin v0.1.2`) — the workflow runs automatically.

> Note: check the exact `--ed-key-file` flag name against the version of `generate_appcast` in use (Sparkle 2.9.3). The flag was introduced in Sparkle 2.x and may have slightly different naming depending on the subversion.

---

## Troubleshooting

### Appcast not picked up by running apps

GitHub Pages can take 1–3 minutes after a `git push origin gh-pages` before the live URL reflects the change. Wait and retry:

```bash
curl -s https://jude-sph.github.io/OpenPhoto/appcast.xml | grep '<title>'
```

If the old content persists past 5 minutes, check the Pages build status in **repository Settings → Pages** — a red X indicates a build failure (usually a file encoding issue).

### Signature mismatch ("update is improperly signed")

This means `generate_appcast` signed the archive with a different private key than the one whose public key is in the running app's `Info.plist`. Check:

1. `scripts/sparkle_public_key.txt` matches the public key printed by `generate_keys` for the Keychain entry used by `generate_appcast`.
2. You haven't run `generate_keys` twice (creating a second Keychain entry). If the Keychain has duplicate `Sparkle` entries, remove the old one in Keychain Access and rebuild.
3. The running app was built with the current `scripts/sparkle_public_key.txt`. If you changed the key after building the installed app, users need to reinstall manually.

### Build number not increasing

Sparkle compares `CFBundleVersion` (the build number) to decide whether a release is "newer". OpenPhoto derives the build number from `git rev-list --count HEAD`, which increases by 1 for every commit.

The build number can appear to go backwards if you rewrite history (`git rebase`, `git commit --amend` with force-push, or cherry-picking to a shorter branch). Avoid history rewrites on `main` after cutting releases. If this happens, find the highest build number in any published `appcast.xml` and ensure your next commit count exceeds it (add empty commits if necessary):

```bash
git log --oneline | wc -l   # check the current count
```

### Framework load crash on launch

If the app crashes immediately on launch with a dyld error mentioning `Sparkle`:

1. Confirm `Sparkle.framework` is in `build/OpenPhoto.app/Contents/Frameworks/`:
   ```bash
   ls build/OpenPhoto.app/Contents/Frameworks/
   ```
2. Confirm the binary's rpath includes `@executable_path/../Frameworks`:
   ```bash
   otool -l build/OpenPhoto.app/Contents/MacOS/OpenPhoto | grep -A2 LC_RPATH
   ```
3. If either is missing, re-run `./scripts/make-app.sh` and verify `swift build -c release` ran at least once so `.build` contains the Sparkle artifact.
