# Keep-awake / idle-timer in core (`Mob.Device.keep_awake/1`)

- Date: 2026-07-04
- Status: accepted
- Issue: MOB-20

## Context

`Mob.Device` could observe screen on/off events but not *prevent* the screen
from dimming/locking — so a video, reader, or navigation screen would sleep
mid-use. This was a Tier-3 gap from the 2026-07-04 capability audit, flagged as
high value-per-effort.

## Decision

- **Core `Mob.Device`, not a plugin.** Like `lock_orientation/1`, keeping the
  screen awake is a permission-free, universal device-state toggle that belongs
  in core. New function `keep_awake(on?) :: :ok`, matching the `Mob.Device`
  convention (takes the value, returns `:ok`) rather than the socket-passthrough
  style of `Mob.Haptic`/`Mob.Torch`.
- **Boolean toggle, no separate state read.** The app owns whether it wants the
  screen kept awake; there's no getter (the flag is write-only OS state). The
  keep-awake flag is app-scoped and the OS clears it on background, so the
  docstring tells callers to re-assert on resume.
- **Wire contract:** `:mob_nif.device_keep_awake/1` takes the boolean atom
  `true`/`false`. iOS reads it and sets `UIApplication.isIdleTimerDisabled` on
  the main thread. Android maps it to an int (1/0) and calls
  `MobBridge.keepAwake(Int)`, which toggles the window's `FLAG_KEEP_SCREEN_ON`
  on the UI thread — the same seam and threading as `lock_orientation`.
- **Graceful drift.** The Android bridge method is cached with `cacheOptional`
  and null-guarded (mirrors `orientationLock`), so an app whose generated
  `MobBridge.kt` predates the method simply no-ops instead of failing to load.

## Consequences

- Cross-repo, one issue: `mob` (Elixir + NIF + iOS + zig) plus `mob_new` (the
  generated `MobBridge.keepAwake` Kotlin method). Existing apps pick it up by
  regenerating their bridge + depending on the mob release that carries the NIF.
- The `keep_awake/1` boolean guard is host-tested; the native effect is
  **device-verified**: moto g power (2021) via `dumpsys` (the app window's
  `fl=KEEP_SCREEN_ON` flag appears on `keep_awake(true)` and clears on `false`),
  and iPhone SE (3rd gen) by observation (screen stays lit past the Auto-Lock
  timeout while enabled, dims when released).
- No permission required on either platform, so no manifest/plist changes.
- Follow-ups if demand appears: a scoped/auto-release variant tied to screen
  lifecycle, and an Android `WakeLock` (CPU-on, not just screen-on) for
  background work — deliberately out of scope here (this is screen-on only).
