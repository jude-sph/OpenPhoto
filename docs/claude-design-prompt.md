# Claude Design prompt — OpenPhoto UI reference mockups

Copy everything below the line into Claude Design.

---

Design the UI for **OpenPhoto**, a native macOS photo library app (think Apple Photos' polish, but folder-first and sovereignty-focused: the library is just regular files in regular folders the user already owns). Produce high-fidelity mockups I'll use as the visual reference for a SwiftUI implementation.

## Design language

- Modern macOS: translucent sidebar material, SF Pro, SF Symbols, generous photo-first layout where chrome recedes and imagery dominates
- Light and dark mode (dark is primary — photos pop)
- Calm and minimal: this app's personality is "quiet, trustworthy archive," not "social photo feed." No gradients-for-gradients'-sake; restraint over flash
- Accent color: pick something warm and distinctive that isn't Apple Photos' palette

## App shell

Left sidebar with sections:
- **Library**: Timeline, Folders, People, Map, Bin
- **Devices** (contextual — only when connected): e.g. "Jude's iPhone", "Canon SD", "T7 Archive ⬩ canonical"
- Bottom of sidebar: a compact background-activity indicator ("Indexing 2,140 of 58,000…")

## Screens to mock (in priority order)

1. **Timeline** — the hero screen. Virtualized photo grid grouped by day/month with sticky date headers and a right-edge year scrubber. Mixed media: photos, videos (duration badge), Live Photos (badge), and *offline* items — photos whose full-res lives on an unplugged drive — shown normally but with a subtle cloud/drive glyph. Toolbar: grid-size slider, filter chips (People, Places, Favorites, Media type), search field.
2. **Folder view** — left: a real folder tree (arbitrary nesting, names like `rome2022`, `mac-screenshots`, `2023/canada23`); folders carry tiny status badges: ✓ synced to drive, ⚠ local-only (not backed up), ◌ offline (evicted). Right: grid of the selected folder.
3. **Import** — "slow and purposeful" device import: a big grid of LARGE thumbnails from a plugged-in iPhone, checkbox selection, "already in library" badges on duplicates, a destination-folder picker (existing or new folder name), and a prominent two-step action: "Import 138 items" → after verification, "Delete imported from iPhone." Show a progress state too.
4. **Sync plan review** — shown when the canonical drive is plugged in. A calm pre-flight summary: "412 new items (3.2 GB) · 18 metadata updates · 2 folder renames · 14 deletions need review", with an expandable deletions section (thumbnails of what will move to the drive's bin) and one primary "Sync" button. Plus a header stat the app leads with: "230 items exist only on this Mac."
5. **Photo viewer + inspector** — full-bleed photo with a toggleable right inspector panel: metadata (date, camera, lens, EXIF), editable fields (caption, tags, rating, people), a small map for GPS, and a **Presence** row showing where this file physically lives ("MacBook ✓ · T7 Archive ✓ · Backup-B —").
6. **People** — face-cluster grid: circular face crops, named people first, then unnamed clusters with confidence hints; hover/selection affordances for merge, split, rename. Include a subtle clustering-threshold slider tucked in a toolbar popover.
7. **Map** — full-bleed map with clustered photo pins (count badges), and a bottom strip showing photos for the selected region.

## States worth showing

- Empty states: first-launch ("Choose your library folders"), empty Bin
- The offline-photo open prompt: "Full resolution is on T7 Archive — plug it in to view"
- Drift warning banner: "3 files on T7 Archive changed outside OpenPhoto — Review"

Mock at 1440×900 minimum. Prioritize screens 1–4 if you must cut.
