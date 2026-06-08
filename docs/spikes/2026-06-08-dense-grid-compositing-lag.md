# Investigation: dense-grid compositing lag on Space switch — findings

**Date:** 2026-06-08
**Status:** Root cause confirmed. Proper fix **deferred to Phase 5** (extras/optimization). Accepted as a known minor issue for now.

## Symptom
With OpenPhoto open on the timeline at **minimum zoom** (the grid packed with hundreds
of tiny thumbnails), a **3-finger Space switch** (Mission Control) causes a ~1-second
**system-wide** hitch — the whole Mac, not just OpenPhoto's UI. It happens even when the
app is completely idle (images just sitting there, no scrolling). At larger zoom (fewer,
bigger cells) it does not occur.

## Investigation (what was measured)
1. **Process is idle during the hitch.** `sample` of the running app: one thread parked in
   the kernel run-loop, **0% CPU**. So OpenPhoto isn't doing any work — the cost is in the
   **WindowServer** (the macOS compositor), which is why the lag is system-wide.
2. **Texture *size* is not the cause.** Rendering thumbnails at display size (down from
   512px, ~7× less texture memory) did **not** help.
3. **Per-cell `GeometryReader` is not the cause.** Gating `.cellFrame` to select mode
   (removing hundreds of GeometryReaders + their preference aggregation while browsing)
   did **not** help.
4. **Decisive experiment.** Rendering the *same number of cells* as plain color tiles
   (no `Image`, no decode) → **perfectly smooth** Space switch. The same cells **with
   thumbnails** → laggy.

## Root cause
Each thumbnail is its own **GPU-textured (IOSurface-backed) CALayer**. Animating a window
with **hundreds of separate textured layers** through a Space transition overwhelms the
WindowServer. Plain color layers are cheap; image-texture layers are not. **It's the
*count* of textured layers, not their size** — which is exactly why (2) didn't help.

Apple Photos shows equally dense grids without this hitch because it does **not** use
hundreds of image views — it renders thumbnails into a **single tiled layer** via a custom
renderer.

## Already done (kept — good regardless)
- **Display-sized thumbnails** (`ThumbnailStore.displayImage` + `ThumbView.targetPixel`):
  cuts texture *memory* and helps general density; keep it.
- **`.cellFrame` gated to select mode**: fewer GeometryReaders/observers while browsing.

## What will NOT fix it
- **Per-cell `.drawingGroup()`** — still one texture per cell, so the texture *count* is
  unchanged.
- **Whole-grid/ScrollView `.drawingGroup()`** — would collapse to one texture and fix the
  Space switch, but the only viewport-sized placement is on the `ScrollView` itself, which
  risks regressing scroll smoothness and tap/scroll interaction. Rejected as a trade-off.

## Proper fix — DEFERRED to Phase 5
A **tiled thumbnail renderer**: composite each on-screen region's thumbnails into a single
(or a few) Metal-backed layer(s), Apple-Photos-style, so the compositor handles a small,
fixed number of layers regardless of grid density. This fixes the Space-switch hitch
*without* the scroll trade-off of a blanket `drawingGroup`. It's a sizable optimization
(its own brainstorm → spec → build cycle) and belongs in Phase 5.

## Interim decision
Accepted as a known, minor issue: it's an occasional ~1s hitch only during a Space switch
at the most extreme zoom, and it doesn't affect scrolling or normal use.
