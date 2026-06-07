# Handoff: OpenPhoto — macOS photo library (SwiftUI)

## Overview
OpenPhoto is a native **macOS** photo library app. Personality: a *quiet, trustworthy archive* — folder-first and sovereignty-focused. The library is just regular files in regular folders the user already owns; OpenPhoto reads/writes standard files in place and never locks originals into a hidden database. Photo-first layout where chrome recedes and imagery dominates.

This bundle contains **7 screens + several states**, presented as one interactive HTML prototype.

## About the Design Files
**The files in this bundle are design references created in HTML/React.** They are prototypes that show the intended *look, layout, and behavior* — they are **not** production code to copy.

Your task is to **recreate these designs natively in SwiftUI** using Apple's frameworks and idioms:
- `NavigationSplitView` for the sidebar + detail shell
- `LazyVGrid` (with section headers) for the photo grids — virtualized for 50k+ items
- **SF Symbols** for all iconography (the HTML uses hand-drawn line icons as stand-ins — see the SF Symbol mapping table below)
- **SF Pro** system font via `.font(...)` text styles (the HTML uses the system font stack to approximate this)
- `.ultraThinMaterial` / `.regularMaterial` for the translucent sidebar and toolbars
- `.toolbar { }` with `ToolbarItem`s for the top bar
- `Color` assets supporting both light & dark appearance
- Real `MapKit` for the Map screen and the inspector mini-map
- The `Photos`/`PhotosUI` and `ImageCaptureCore` frameworks are the natural fit for device import, but the *visual design* is what this doc specifies.

Do not embed a WKWebView. Rebuild the UI in SwiftUI.

## Fidelity
**High-fidelity.** Colors, spacing, typography, and interactions are intentional. Recreate the UI faithfully, adapting only where a native macOS idiom is clearly better (e.g. use a real `Slider`, `Toggle`, `DisclosureGroup`, context menus, and standard window chrome instead of the mocked traffic lights — on a real macOS app the OS draws those).

---

## Design Tokens

### Color — Dark (primary appearance)
| Token | Hex | Use |
|---|---|---|
| Accent | `#CF5C57` | selection, primary buttons, active sidebar item, canonical badge. Warm coral-red, deliberately *not* Apple Photos blue. |
| Accent hi (hover) | `#D87B76` | button hover |
| Accent dim | `rgba(207,92,87,0.16)` | tag chips, icon tile backgrounds |
| Window bg | `#1B1917` | content background |
| Bg-2 | `#211F1C` | cards, footers, side panels |
| Elevated | `#2A2724` / `#322F2B` | menus, popovers |
| Sidebar | `rgba(34,31,28,0.62)` over `.ultraThinMaterial` | translucent sidebar |
| Text | `#ECE9E4` | primary |
| Text dim | `#A39E97` | secondary |
| Text faint | `#726D66` | tertiary / counts |
| Hairline | `rgba(255,255,255,0.085)` | dividers |
| Tile | `#2C2926` | empty photo cell |
| Green (synced) | `#5FB47A` | ✓ synced status |
| Amber (local-only) | `#D8A23E` | ⚠ local-only / deletions |
| Blue (metadata) | `#6AA3D8` | metadata-update accents |

### Color — Light appearance
| Token | Hex |
|---|---|
| Window bg | `#F7F5F2` |
| Bg-2 | `#F1EEEA` |
| Elevated | `#FFFFFF` |
| Sidebar | `rgba(247,245,242,0.68)` |
| Text / dim / faint | `#211E1B` / `#6C6862` / `#9A958D` |
| Hairline | `rgba(0,0,0,0.10)` |
| Tile | `#E7E3DD` |
| Green / Amber / Blue | `#3F9D5F` / `#B9852A` / `#3F7FBF` |
| Accent | `#CF5C57` (same in both) |

> Accent has 3 alternates the prototype lets you toggle — ship coral-red as default; the others are exploratory: terracotta `#D9694C`, amber `#E8845B`, brass `#C99A3F`.

### Typography (SF Pro / system)
| Role | Size | Weight | Notes |
|---|---|---|---|
| Screen title (toolbar) | 15 | 600 | |
| Day/section header | 16 | 700 | letter-spacing −0.01em |
| Sidebar item | 13.5 | 500 | |
| Sidebar section label | 11 | 600 | uppercase, +0.04em, faint |
| Body / metadata | 13 | 400–600 | |
| Counts / EXIF values | 12–13 | 600 | **tabular numbers** (`.monospacedDigit()`) |
| Hero stat ("230") | 52 | 700 | letter-spacing −0.03em, accent color |
| File paths | 11 | 400 | monospaced (SF Mono) |

### Spacing & shape
- Grid gap: **3px** (timeline), **10px** (import large thumbs), **8px** (face grid)
- Photo cell radius: **3px**; card radius: **12–14px**; button radius: **8px**; chip radius: **7px**
- Window radius: **11px**; window shadow: `0 32px 80px rgba(0,0,0,.55)`
- Sidebar width: **248px**; folder tree column: **250px**; inspector: **332px**
- Toolbar height: **52px**
- Hit targets ≥ 28px controls, ≥ 44px for primary touch-like actions

---

## Screens / Views

### 1. Timeline (hero)
- **Purpose:** Browse the whole library chronologically.
- **Layout:** Toolbar (title + "58,212 photos · 4,108 videos" + filter chips + grid-size slider + search) over a vertically scrolling `LazyVGrid`. Photos grouped by **day** (recent) and **month** (older) with **sticky section headers** showing date + place. A **right-edge year scrubber** (2025…2022) appears on hover/scroll and highlights the current year.
- **Cells:** square-cropped, `aspectRatio(1, contentMode: .fill)`. Hover = subtle 1.045 scale on the image.
- **Badges:** top-right LIVE badge (concentric-circles symbol) for Live Photos; video shows a ▶ + duration ("0:24") pill bottom or top-right; favorites show a small filled heart bottom-right; **offline** items are rendered normally but dimmed (~0.82 brightness) with a small drive-slash glyph top-right.
- **Filter chips:** People, Places, Favorites, Media type — toggle to accent-filled when active.
- **Grid-size slider:** drives cell min-width 92→220px.

### 2. Folder view
- **Purpose:** Browse the real on-disk folder hierarchy.
- **Layout:** 3-pane feel — main sidebar | folder tree (250px) | photo grid. Breadcrumb in toolbar ("2025 › lisbon25"), item count + size, "Reveal in Finder" chip.
- **Folder tree:** arbitrary nesting (`DisclosureGroup`), names like `lisbon25`, `mac-screenshots`, `2023/canada23`, `wedding-raw`, `_inbox`. Each row has a **status badge**: ✓ synced (green circle), ⚠ local-only (amber), ◌ offline/evicted (faint drive-slash), plus an item count. Legend at the bottom of the tree.
- **Drift banner** (dismissible, amber): "3 files on T7 Archive changed outside OpenPhoto — Review."

### 3. Import (device)
- **Purpose:** "Slow and purposeful" import from a connected iPhone/SD.
- **Layout:** Big grid of **large** thumbnails (min 178px, 10px gap, 10px radius) with a circular checkbox top-left. Header: "Jude's iPhone · 15 new since last import · 1.9 GB" + Select all / Deselect. Sticky **footer action bar**.
- **Duplicates:** items already in the library are greyed + non-selectable with an "Already in library" pill.
- **Footer (select phase):** "12 of 15 selected · 3 already in library, skipped" + a **destination folder picker** (Menu: existing folders or "New folder…") + a prominent **"Import 12 items"** primary button.
- **Footer (importing phase):** progress bar + "Copying & verifying… 64% · checksum verified before any deletion."
- **Footer (imported phase):** green check "12 items imported & verified into lisbon25" + secondary **"Done"** + destructive **"Delete 12 imported from iPhone"** (this is the deliberate two-step: import & verify *first*, delete from device *second*).

### 4. Sync plan review
- **Purpose:** Calm pre-flight before syncing to the canonical drive (T7 Archive).
- **Layout:** Toolbar shows the drive name + "canonical" badge + "Connected · last sync 6 days ago." Centered column (max 760px):
  - **Lead stat:** big "**230**" + "items exist only on this Mac" + a 3-segment bar (mac / T7 / no-backup).
  - **Sync plan card** rows: `412 new items (3.2 GB)`, `18 metadata updates`, `2 folder renames` (canada23 → 2023/canada23 · _new → inbox), `14 deletions need review` — the last is an **expandable** row revealing a wrap of deletion thumbnails + "Keep all / Review each."
  - **Footer:** reassurance copy ("Sync is one-way to the canonical drive") + "Schedule for later" + primary **"Sync to T7 Archive."** On success, a green completion banner.

### 5. Photo viewer + inspector
- **Purpose:** Full-screen single-photo view with metadata/edit.
- **Layout:** Dark full-bleed stage with the photo contained + soft shadow. Top bar: back, title (place · date), favorite / share / crop, and an **inspector toggle**. Bottom **filmstrip** of neighboring thumbnails (current = accent outline). ← / → / Esc / `i` keyboard nav.
- **Inspector (332px, right):** date/time; **editable caption** field; **5-star rating**; **People** chips (face crop + name + "Add"); **Tags** (removable chips + add); divider; **camera + EXIF grid** (ISO, aperture ƒ, shutter, focal mm, dimensions, file size/type); **Location** mini-map (use MapKit) with coordinates; divider; **Presence row** — the signature feature: "MacBook ✓ · T7 Archive ✓ · Backup-B —" each as a row with a drive symbol and on/off state; then the real **file path** in mono.
- **Offline-open prompt:** when an offline photo is opened, show a blurred preview behind a card: "Full resolution is on T7 Archive — A preview is shown. Plug in the drive to view, edit, or export the original." with "Show preview" / "Locate drive."

### 6. People
- **Purpose:** Face clustering + naming.
- **Layout:** Circular face crops in a `LazyVGrid`. **Named** people first (larger, ~108px circles, name + count). Then **"Clusters to review"** — unnamed clusters (smaller) with a confidence hint ("· 94%"). Selecting one or more reveals action chips: **Merge** (≥2), **Name**, **Not a person**, **Clear**. A **clustering-threshold** popover (slider Loose↔Strict, "72% confidence · re-clusters 214 people") lives behind a toolbar "Clustering" button.

### 7. Map
- **Purpose:** Geographic browse.
- **Layout:** Full-bleed map (**use MapKit**) with **clustered pins** — each pin is a small circular photo thumbnail + a count badge ("642"). Selected pin = accent fill. A **bottom strip** shows photos for the selected region with a header ("Lisbon · 642 photos · Sep 2022 – Jun 2025" + "Open in Timeline"). The HTML uses an abstract CSS map; replace with a real `Map` view.

### States
- **First-launch (empty):** centered welcome card — aperture mark, "Welcome to OpenPhoto," sovereignty copy, a list of chosen library folders (path + photo count + "canonical" badge / ✓ ready / remove), "Choose a folder…" dashed button, a reassurance note, and "Learn how it works" / "Open library."
- **Empty Bin:** centered bin symbol + "Bin is empty" + "Deleted photos rest here for 30 days… Nothing leaves your drives until you empty it."
- **Drift warning banner:** see Folder view.
- **Offline-open prompt:** see Viewer.

---

## Interactions & Behavior
- **Sidebar navigation** switches the detail view. Sidebar sections: **Library** (Timeline, Folders, People, Map, Bin), **Devices** (contextual — only when a device/drive is connected: "Jude's iPhone", "Canon SD", "T7 Archive ⬩ canonical"), **Albums**.
- **Background activity indicator** pinned to the sidebar bottom: spinner + "Indexing library" + progress bar + "2,140 of 58,000 · faces & metadata." Animate the count upward.
- **Timeline:** hover scale on cells; year scrubber tracks scroll position; clicking a cell opens the Viewer.
- **Viewer:** ←/→ navigate, Esc closes, `i` toggles inspector; star rating and tag removal are interactive; offline photos gate the full-res behind the prompt.
- **Import:** two-phase progress (importing → imported); destination Menu; duplicates non-selectable.
- **Sync:** expandable deletions `DisclosureGroup`; primary Sync swaps to a success banner.
- **People:** multi-select → merge/name; threshold popover.
- **Transitions:** keep them calm — short fades/cross-dissolves, no flashy motion. Respect Reduce Motion.

## State Management
Model these as `@Observable` / `ObservableObject` stores:
- **LibraryStore:** photos (id, type, date, place, coordinates, folder, favorite, rating, caption, tags, people, EXIF, **presence** per storage node, **offline** flag), grouped sections for timeline.
- **DeviceStore:** connected devices/drives (drives a contextual sidebar section), import candidates (+ duplicate detection), import phase + progress.
- **SyncStore:** pending plan (new/metadata/renames/deletions), Mac-only count, sync progress.
- **PeopleStore:** clusters (named + unnamed + confidence), selection, clustering threshold.
- **AppState:** selected sidebar item, selected folder, open photo, inspector visibility, appearance (light/dark — defer to system), accent.

## SF Symbol mapping (HTML icon → SF Symbol)
| HTML icon | SF Symbol |
|---|---|
| timeline | `calendar` / `photo.on.rectangle.angled` |
| folders / folderOpen | `folder` / `folder.fill` |
| people / person | `person.2.fill` / `person.crop.circle` |
| map / mappin / pin | `map` / `mappin` / `mappin.circle.fill` |
| bin | `trash` |
| iphone / sd / drive / externalDrive | `iphone` / `sdcard` / `internaldrive` / `externaldrive` |
| driveSlash (offline) | `externaldrive.badge.xmark` / `icloud.slash` |
| heart / heartFill | `heart` / `heart.fill` |
| star / starFill | `star` / `star.fill` |
| live | `livephoto` |
| play / film | `play.fill` / `film` |
| check / seal | `checkmark` / `checkmark.seal` |
| warn | `exclamationmark.triangle` |
| sync | `arrow.triangle.2.circlepath` |
| camera / lens | `camera` / `camera.aperture` |
| sliders | `slider.horizontal.3` |
| inspector | `sidebar.right` |
| search | `magnifyingglass` |
| share | `square.and.arrow.up` |
| crop / rotate | `crop` / `arrow.counterclockwise` |

## Assets
- **No bundled image assets.** The prototype uses placeholder photographs from `picsum.photos` (seeded URLs) purely to populate grids. In the real app these come from the user's actual library files. Face crops are likewise placeholders.
- Icons → SF Symbols (table above). No custom icon assets required.

## Files (design references in this bundle)
- `OpenPhoto.html` — entry; open this to run the prototype.
- `app.css`, `screens.css` — all visual tokens & per-screen styling (authoritative source for exact colors/spacing).
- `app.jsx` — shell, routing, theme, accent logic.
- `shell.jsx` — sidebar, background-activity indicator, shared photo cell + badges.
- `timeline.jsx`, `folders.jsx`, `import.jsx`, `sync.jsx`, `viewer.jsx`, `people.jsx`, `map.jsx`, `states.jsx` — one per screen/state.
- `data.jsx` — sample data model (mirror these fields in your Swift models).
- `icons.jsx` — placeholder icon paths (map to SF Symbols, don't port).
- `tweaks-panel.jsx` — prototype-only control panel; **ignore** for production.

To run the reference: open `OpenPhoto.html` in a browser (needs network for placeholder photos). Use the floating **Tweaks** panel to switch appearance, accent, density, and jump between screens/states.
