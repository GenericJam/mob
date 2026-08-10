# Colour verification samples pixels: crop in the NIF, reduce in Elixir

- Date: 2026-08-10
- Status: accepted

## Context

`decisions/2026-08-09-view-tree-colour-needs-screenshot-sampling.md` established
that no view- or layer-tree property can report the colour of SwiftUI-rendered
content on iOS 26, and named the follow-up: a sampling helper. The bug that
motivates it is a glass theme under which mob's iOS renderer discarded every Box
background, so `background: :primary` and `background: :surface_raised` rendered
identically — found only by pixel-diffing screenshots by hand.

Three things had to be decided: where the crop happens, what a "colour" for a
region even is, and whether the capture primitive may ship in release builds.

## Decision

**Crop natively.** `:mob_nif.sample_region(X, Y, W, H)` renders the window with
the crop rect offset to the context origin, so only the region's pixels are
allocated and only they cross Erlang distribution. Returning a framebuffer and
cropping in Elixir would move megabytes per assertion. It reuses `screenshot/3`'s
capture path — both now call `mob_capture_window()` + `mob_capture_image()`, so
there is one window-picking and one rendering code path, not two.

Coordinates are window points, the same space `element_frames/0` reports, so
`Mob.Test.sample_color(node, "my-card")` resolves a rect through `frame/2` with no
unit conversion. Rects are clamped to the window; a rect entirely outside it is
`{:error, :offscreen}`, never a plausible-looking black.

**Reduce in pure Elixir, and report more than a mean.** `Mob.Test.reduce_rgba/3`
takes the buffer plus its dimensions and returns `%{average, dominant,
dominant_share, distinct, pixels}` — all colours `0xAARRGGBB`. A region is rarely
one flat colour (a card has text, a border, antialiased corners), so a bare mean
of a mostly-background region is misleading in both directions: it is *not* the
background, and it is not the text. `:dominant` (most frequent exact pixel, ties
broken toward the higher value so it is deterministic) is the background of a flat
fill; `:dominant_share` and `:distinct` tell the caller whether to believe it —
high share means a flat fill, low share means a gradient where only `:average`
carries meaning. Being pure and dimension-checked, it is unit-testable without a
device, and a buffer that doesn't match its declared size returns
`{:error, :size_mismatch}` rather than a colour derived from partial data.

**`sample_region/4` stays `#if !MOB_RELEASE`** — *not* `#if !MOB_RELEASE ||
defined(MOB_ENABLE_SCREENSHOT)` like its neighbour. It uses only public UIKit, so
App Store validation is not the constraint; the constraint is that arbitrary-rect
pixel reads reconstruct the screen region by region, which would silently give a
release build the capability `MOB_ENABLE_SCREENSHOT` exists to make a conscious
opt-in. Colour verification is a dev-time need — a shipped agent wants
`screenshot/3` to see the screen, not a sampling probe. `Mob.ReleaseScreenshotTest`
pins the guard so the distinction survives a future edit.

## Consequences

- A styling regression is now detectable programmatically: sample two Boxes and
  compare `:dominant`. Equal samples for `:primary` vs `:surface_raised` reproduce
  the original bug.
- iOS only. Android needs the same crop-in-the-render treatment against the
  activity window; until then `sample_color/2` returns `{:error, {:badrpc, _}}`
  there, and the platform matrix in `Mob.Test` says so.
- Payload is `w * h * screen_scale² * 4` bytes (a 100x50pt element ≈ 180 KB at
  3x). Sampling element frames is cheap; a full-screen rect is not, and the
  docstring says not to.
- The reduction runs in the BEAM over a binary, so a very large region costs CPU
  on the device. Same guidance: sample elements, not screens.
