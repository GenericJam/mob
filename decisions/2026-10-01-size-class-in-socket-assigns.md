# The window's size class is a socket assign, kept current by native

- Date: 2026-10-01
- Status: accepted
- Tickets: MOB-204 (iPhone Duo epic MOB-200), mob side of MOB-165 (iPad letterbox)

## Context

Apple's guidance for iPhone Duo, and for iPad before it, is to lay out by size
class, not by orientation or raw dimensions: an iPad in Slide Over is a
phone-shaped window on a tablet, and a foldable flips class when it opens. mob
gave screens no size class at all. On iPad that was invisible only because
generated apps were iPhone-only and letterboxed to 320x480 (MOB-165); once the
template advertises iPad (MOB-206), screens run in windows that resize under
them — rotation, Split View, Slide Over, Stage Manager — and need a signal to
re-lay out.

`:safe_area` already reaches every socket and is the model: read at mount,
present before `mount/3`, corrected by native when the window changes.

## Decision

- **`assigns.size_class` on every socket**, `{horizontal, vertical}`, each
  `:compact | :regular`, written before `mount/3` like `:safe_area`. Screens
  read it directly; it is never missing.
- **Read at mount** through a new NIF, `mob_nif:size_class/0`, answering
  `{H, V}` or `no_window`. `Mob.SizeClass.read/1` turns every non-answer —
  `no_window`, an error, a stub or a native library that predates the NIF (a
  hot-pushed mob on an app whose native layer was not rebuilt) — into the
  placeholder `{:compact, :regular}` rather than a crash on the mount path.
- **Native pushes changes**: `{:mob_size_class, H, V}` to the `:mob_screen`
  router. The router sends it to **every live screen** — current, history and
  parked tabs — not only the visible one, unlike `{:mob_window, :connected}`.
  Each screen holds its own copy of the assign, and a screen popped back to or
  a parked tab switched to must already have the class of the window it
  reappears in; nothing else would tell it.
- **Screens hear about it as `handle_info({:mob_size_class_changed, new},
  socket)`**, after the assign is written, so a screen that only reads the
  assign in `render/1` needs no clause. A value the screen already holds is
  dropped with no callback and no paint, because native reports on every trait
  or configuration pass, not only on a change.
- **A screen with no clause for the message is not crashed.** The framework
  sends it unprompted, to every screen, on every rotation, and a screen that
  overrides `handle_info/2` without a catch-all would otherwise lose its state
  each time the device turned. Only a head mismatch on exactly this message is
  tolerated (the top stack frame is the screen's own `handle_info/2` called
  with it); a crash inside a matching clause still crashes the screen.
- **Persisted screens end on the live value, and re-derive.** `load_state/2`
  output is merged over the mounted socket, and a dump from an earlier window
  carries that window's class and whatever the screen derived from it. The
  persisted class is kept through the merge and the live one is then applied
  as an ordinary change, so a difference reaches the screen's
  `{:mob_size_class_changed, _}` clause instead of leaving stale derived
  assigns.
- **`Mob.ScreenCase`** mounts with the placeholder or `size_class:` from the
  new `mount_screen/4` opts, and `change_size_class/2` applies a change through
  the same function the screen process uses (`Mob.SizeClass.apply_change/3`),
  so a test sees exactly what a device does.

### iOS

`nif_size_class` reads the first window's `traitCollection` on the main thread
with the same bounded (2 s) wait as `nif_safe_area`; a timeout, no window or an
unspecified class answers `no_window`. Changes come from `MobRootView`, which
observes SwiftUI's `horizontalSizeClass` / `verticalSizeClass` environment as
**one equatable pair** with `onChange(..., initial: true)`. One pair, because a
rotation flips both axes in one trait update and two observers would report a
half-changed intermediate (`{:regular, :regular}` between portrait and
landscape). `initial: true`, because the first report is what corrects a screen
that mounted before the window existed (a prewarmed launch).

### Android: `Configuration` dp with Material breakpoints

Android has no OS size class. Options considered:

1. **Compose `WindowSizeClass`** (`material3-window-size-class`). Needs a new
   Gradle dependency and a `@Composable` call site in `MainActivity`, i.e. a
   `mob_new` template change; apps generated before it would never report.
2. **`WindowMetrics` bounds** (what Compose and Jetpack WindowManager compute
   from). API 30+ only; `MobBridge.screenInfo`'s pre-30 path measures the decor
   view, which has not been re-laid out yet when `onConfigurationChanged` runs,
   so a change would report the old size. It is also a UI-thread round trip.
3. **`Configuration.screenWidthDp` / `screenHeightDp`** with Material's
   breakpoints: horizontal `:regular` from 600dp, vertical from 480dp; Material
   "medium" and "expanded" both map to `:regular`.

Chose 3. It is a field read from any thread (no UI-thread hop), already updated
when `onConfigurationChanged` runs on every supported API level, and it needs
no Kotlin, so existing apps get it from a native rebuild. The breakpoints are
the ones Android's own `w600dp` / `h480dp` resource qualifiers select on.
Before Android 15 (and for apps not targeting SDK 35; the template targets 35)
Configuration excludes the system bars, so there a window within a bar's height
of a breakpoint can classify differently than WindowMetrics would.

Changes are reported from `mob_send_orientation_changed`, which the template's
`MainActivity.onConfigurationChanged` already calls on **every** configuration
change it handles (its manifest declares `orientation|screenSize|screenLayout`),
and from `_mob_bridge_init_activity`, for a resize that recreates the activity
(crossing `smallestScreenSize`, which the manifest does not handle).

## Consequences

- Requires a native rebuild (`mix mob.deploy --native`) to report real values.
  Without one, screens hold `{:compact, :regular}` and never change.
- iPad apps fill the screen only once the app's `Info.plist` declares
  `UIDeviceFamily` `[1, 2]` — the template half of MOB-165, landing as MOB-206.
- The typical values in `Mob.SizeClass`'s docs follow from the platform, not
  from mob: a smaller iPhone in landscape is `{:compact, :compact}`; only the
  large ones (Plus, Pro Max) reach `{:regular, :compact}`.
- iPhone Duo's fold flips the trait collection, which this already observes;
  verifying that waits on the Xcode 27.1 Duo simulator (MOB-205).
- Every live screen does a little work per change, even screens under the top
  of a stack. A change is a rotation or a resize, not a hot path.
