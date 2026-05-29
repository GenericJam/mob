# In-process screenshot + scroll control via the bridge NIF

- Date: 2026-05-29
- Status: accepted

## Context

`Mob.Test` already drives Mob apps fully over Erlang distribution (state reads,
taps, navigation, synthetic touches) with no adb/xcrun. The one remaining hard
dependency on external device tooling was the *observe-visually* half of the
agent loop: `PLAN.md`'s Layer 5 (Visual) is "MCP, external" — screenshots came
only from `xcrun simctl io` / `adb screencap`. There was also no way over dist
to read a scroll view's offset/extent or command it to a position (only the
imprecise `swipe_xy` and iOS-AX-only `ax_action :scroll_*`).

This blocks Sloppy Joe and WireTap, which must be programmable by a remote agent
that can only reach the device over dist. The agent needs eyes and deterministic
scroll through the bridge NIF itself.

## Decision

Add three test-harness NIFs, surfaced on `Mob.Test`:

- `screenshot/3` (format, quality, scale) → PNG/JPEG bytes, returned over dist.
- `scroll_info/1` (id) → flat JSON `{offset,content,viewport,max,kind}`.
- `scroll_to/3` (id, x, y) → absolute offset (clamped by the Elixir wrapper).

`Mob.Test` adds `screenshot/2`, `scroll_info/2`, `scroll_to/4`, and
`screenshot_tour/3` (page top→bottom, capture each). Target resolution
(`:top`/`:bottom`/`{:page,n}`/`{x,y}`) and the tour paging are pure, unit-tested
helpers; the NIF stays a dumb absolute setter.

Scroll views are addressed by their `:id` prop:

- **iOS**: the SwiftUI renderer applies `node.nativeViewId` as the scroll view's
  `accessibilityIdentifier`; the NIF walks `UIScrollView`s and matches it. In
  practice SwiftUI does **not** reliably propagate `.accessibilityIdentifier` onto
  the backing `UIScrollView` (verified on-device 2026-05-29), so the NIF falls back
  to the largest scroll view (the main content scroller) when an explicit id does
  not match — correct for the common one-scroll-per-screen case. Pixel units.
- **Android**: the Compose renderer registers each `:scroll`/lazy-list state in an
  id-keyed registry in `MobBridge` (with the measured viewport for `ScrollState`,
  which doesn't expose it). `kind` is `"pixel"` for `verticalScroll`/`ScrollState`
  and `"index"` for `LazyColumn`/`LazyListState` (y is an item index, viewport is
  the visible-item count). The `kind` field makes the asymmetry explicit so paging
  stays coherent in either unit.

Capture is in-process: iOS `UIGraphicsImageRenderer` + `drawViewHierarchy`;
Android `PixelCopy` against the activity window (decor-view `draw` fallback
pre-API-26). Both are debug-only harness code (iOS `#if !MOB_RELEASE`).

This is core test-harness work (same bucket as `ui_tree`/`tap_xy`), not a
plugin-shaped feature, so it lands under the current plugin-first hold.

## Consequences

- A remote agent gets pixels + deterministic scroll with zero adb/xcrun — the
  capability `wiretap_screenshot` will build on.
- Capture is the app's own surface only; `FLAG_SECURE` (Android) and secure text
  fields (iOS) render blank, and a backgrounded app has no window (returns
  `{:error, :no_window}` / not_found).
- Cross-repo: the Android side spans `mob` (Zig NIF) and the `mob_new`
  `MobBridge.kt.eex` template; existing apps pick it up on regeneration or a
  manual `MobBridge.kt` patch.
- `:scroll` (ScrollState) is not persisted across BEAM re-renders the way lists
  are; the registry holds the live state, which is current during a scroll→shot
  tour. Persisting it by id is a possible follow-up.
- The Compose-semantics walker for arbitrary (non-Mob) apps remains deferred to
  WireTap (see `future_developments.md`); this change covers Mob-rendered apps.
