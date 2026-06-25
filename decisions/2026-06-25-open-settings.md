# Mob.Device.open_settings/1 — open OS settings (cacheOptional, not cacheRequired)

- Date: 2026-06-25
- Status: accepted

## Context

Screens could hand a URI to the OS (`Mob.Device.open_url/1`) but could not
deep-link into OS **settings screens**, which are Intent actions, not URIs.
Needed for (a) recovering from a *permanently* denied runtime permission (send
the user to the app's settings page) and (b) special-access permissions like
`SCHEDULE_EXACT_ALARM`, whose only grant path is a system settings screen.

## Decision

Add `Mob.Device.open_settings(target \\ :app)` where `target` is `:app`,
`:notifications`, or `:exact_alarm`, mirroring the `open_url` NIF path across all
layers (Elixir, `src/mob_nif.erl` export/nifs/stub, `android/jni/mob_nif.zig`
struct + nif + native nif-table + cache, `ios/mob_nif.m` nif + table). Invalid
targets return `{:error, :invalid}` (no NIF call), matching `lock_orientation/1`.

The Android Kotlin bridge method (`MobBridge.openSettings(String)`) is cached
with **`cacheOptional`, not `cacheRequired`**, and `nif_open_settings`
null-guards `Bridge.open_settings`. Reason: the Kotlin `MobBridge` is app-owned
(scaffolded from the `mob_new` template) and drifts — a `cacheRequired` entry for
a method a stale `MobBridge.kt` lacks would fail `nif_load`, which makes the
**entire `mob_nif` module `undef` at boot** (the 0.7.6 regression class, fixed in
0.7.7). `cacheOptional` + the null guard degrade to a silent no-op instead.

iOS exposes only the single app settings page (`UIApplicationOpenSettingsURLString`),
so `target` is validated but otherwise ignored there.

## Consequences

- The Kotlin `openSettings` method must be added to the `mob_new` template and
  scaffolded into apps. Until an app refreshes its `MobBridge.kt`,
  `open_settings/1` is a silent no-op on Android (by design, never a crash).
- `nif_stub_test` guards the erl export/nifs/stub agreement automatically; the
  native nif-table entry is verified by booting on a device (host `mix test`
  cannot catch a native-table mismatch).
- Consumers need mob at or above the release that carries this (target 0.7.8).
