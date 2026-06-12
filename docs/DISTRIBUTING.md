# Distributing OpenPhoto

This document explains what to share with someone who wants to use OpenPhoto, how they install it, and how updates work for them. It also covers what NOT to share.

---

## What to send

**Send:** `build/OpenPhoto-<version>.dmg`

This is the only file a recipient needs. Build it with:

```bash
./scripts/make-dmg.sh
```

The DMG contains:
- `OpenPhoto.app` — the app itself, with a full multi-size icon and a self-contained `Sparkle.framework` for auto-updates.
- An `Applications` symlink — drag-to-install layout.
- `READ ME FIRST.txt` — brief install instructions (shown when the DMG opens).

**Do NOT send:**

- `scripts/sparkle_public_key.txt` — this is the EdDSA *public* key, which is harmless on its own, but there's no reason to send it. The key is already embedded in the app inside the DMG.
- The contents of your login Keychain. The EdDSA *private* key lives there and must never leave the developer's machine.
- The raw `.app` folder (it will have the macOS quarantine flag; use the DMG). The DMG is also self-contained with instructions.
- Any source code or `.build` artifacts.

---

## How the recipient installs it

### Step 1: Open the DMG

Double-click `OpenPhoto-<version>.dmg`. macOS mounts it and a window opens showing the app and an `Applications` folder shortcut.

### Step 2: Drag to Applications

Drag `OpenPhoto.app` onto the `Applications` folder icon.

### Step 3: Get past the Gatekeeper warning (one time only)

OpenPhoto is not signed with a paid Apple Developer ID. The first time you open it, macOS will show a warning saying it "cannot be verified" and refuse to open it directly.

**Option A — Right-click method (macOS 14 and earlier):**

1. In Finder, open your `Applications` folder.
2. Right-click (or Control-click) on `OpenPhoto`.
3. Choose **Open** from the menu.
4. In the dialog that appears, click **Open** again.

**Option B — System Settings method (macOS 15+, Sequoia):**

The right-click trick no longer works on macOS 15 (Apple removed that path). Instead:

1. Try to open OpenPhoto normally (double-click). macOS shows the warning and moves it to Trash or blocks it.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the **Security** section.
4. You will see a message: `"OpenPhoto" was blocked from use because it is not from an identified developer.`
5. Click **Open Anyway**.
6. Authenticate with Touch ID or your password.
7. Launch OpenPhoto again from Applications.

**Option C — Terminal fast path (any macOS version):**

If you're comfortable with Terminal, this is the quickest method:

```bash
xattr -dr com.apple.quarantine /Applications/OpenPhoto.app
```

Then open OpenPhoto normally. No dialog will appear.

**Option D — USB stick delivery (no Gatekeeper at all):**

If you copy the `.app` to a USB stick (FAT32 or exFAT) and install from there, macOS never applies the quarantine attribute, so no "Open Anyway" step is needed. The recipient just drags from the USB stick to Applications and opens normally.

> **You only do this once.** After you've opened OpenPhoto once (using any of the above methods), it will open normally from then on. Future updates are installed silently by Sparkle — no second Gatekeeper prompt.

---

## First launch

On first launch, OpenPhoto shows a Welcome screen asking you to choose your photo folder.

**Choose your `~/Pictures` folder** (or whatever folder your photos live in). Click **Choose your photo folder…**, navigate to the folder, and click **Open library**.

> **Important:** Do NOT choose the `Photos Library.photoslibrary` package. That is Apple's internal database file — it's not a folder of normal photos. OpenPhoto indexes standard image and video files in regular folders, not Apple's private library format.

OpenPhoto will scan the folder and build its index. Depending on the size of your library, this may take a few seconds to several minutes on first run.

Your photos are **never modified**. OpenPhoto only reads them to index and display. If you delete the app, your files are completely untouched.

---

## How updates work

OpenPhoto uses [Sparkle](https://sparkle-project.org) to deliver automatic updates.

- **On first launch**, Sparkle will ask once whether you want to enable automatic background update checks. Choose **Automatically check for updates** for the smoothest experience.
- **Automatic checks** happen roughly once a day in the background. When a new version is available, Sparkle shows a small prompt: "A new version of OpenPhoto is available. Would you like to update?" Click **Update** — the app downloads the new version, verifies its signature, and relaunches automatically.
- **Manual check:** at any time, open the App menu (top-left menu bar while OpenPhoto is in focus) and choose **Check for Updates…**
- **No reinstall needed.** Updates install in-place; you don't repeat the DMG drag-install.
- **No second Gatekeeper prompt.** Sparkle strips the quarantine attribute from each update it installs, so subsequent updates open silently regardless of your macOS version.
