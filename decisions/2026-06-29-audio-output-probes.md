# Audio output probes — verify sound is actually working

- Date: 2026-06-29
- Status: accepted

## Context

Mob can verify *visual* output in-process via the `screenshot/3` NIF (reads the
composited framebuffer; see `Mob.Test`). There was no equivalent for *audio*:
nothing could answer "is sound actually coming out right now." This surfaced
bringing up Doom (the `mob_doom` plugin) in a mob app — Doom drives its own
`AudioTrack` at 11025 Hz from a polling thread, and there was no programmatic
way to tell working audio from silence.

`adb shell dumpsys audio` / `dumpsys media.audio_flinger` already answer much of
this from outside the app on Android (active players + state, stream volume +
mute, mixer-track underrun counters). But they cannot distinguish a live signal
from pushed silence, and they do not exist on iOS. These probes are the
in-process, cross-platform layer on top of that.

Audio has no single "final surface" the way the framebuffer is for video, so we
expose two probes at two vantage points rather than one screenshot-equivalent.

## Decision

Add two read-only NIF-backed functions to `Mob.Audio`:

- `output_status/0` → `%{volume, muted, route, other_audio}`. Cheap,
  synchronous, no permission. Catches the common "no sound" causes (muted,
  volume 0, dead route). iOS: `AVAudioSession`. Android: `AudioManager`.
- `output_level/1` → `{rms_db, peak_db}` | `:silent` | `{:error, reason}`. Reads
  actual signal energy — the part `output_status` and `adb` cannot answer. Takes
  a `:source`:
  - `:mob` (default) — meters `Mob.Audio`'s own player. iOS: `AVAudioPlayer`
    metering (free, no permission). Android: `Visualizer` on the player's **own
    audio session** (needs `RECORD_AUDIO`, runtime-granted). `{:error,
    :not_playing}` when no `Mob.Audio` playback is active.
  - `:mix` — *would* tap the global output mix to observe audio that bypasses
    `Mob.Audio` (a game's own `AudioTrack`, another app). **Not available to a
    normal app** on either platform → `{:error, :unsupported_on_platform}`.
    Device-verified: a session-0 `Visualizer` on Android 11 fails with
    `ERROR_NO_INIT` even with `RECORD_AUDIO` + `MODIFY_AUDIO_SETTINGS` (global
    output capture is privileged); iOS forbids it by sandbox. Global
    device-audio capture belongs in a separate MediaProjection-based plugin
    intended as a **test-environment dependency**, not the core framework.

Native wiring mirrors `screenshot/3` and `open_settings/1`: `-export` + `-nifs` +
stub in `src/mob_nif.erl`; native table entries in `android/jni/mob_nif.zig` and
`ios/mob_nif.m`; and **`cacheOptional` + null-guard** for the app-owned Android
bridge methods so a drifted `MobBridge.kt` no-ops (NIF returns an error atom)
instead of failing `nif_load` and crash-looping boot (the 0.7.6 lesson). The
Android bridge methods ship in the `mob_new` template; iOS level-2 is
self-contained in `mob_nif.m`. `output_level` is a dirty IO NIF (Android settles
a Visualizer window; iOS `dispatch_sync`s to the main queue).

The NIFs return only doubles / bare atoms (no term-building in C/Zig); `Mob.Audio`
decodes route codes and the `:silent`/`:error` shapes in pure Elixir
(`decode_status/1`, `decode_level/1`, unit-tested on host).

## Consequences

- **Honest scope:** the in-app probes verify *your own* audio only. Metering a
  foreign native player (a bundled game's `AudioTrack`, another app) is not
  possible for a normal app on either platform — the global-mix tap is privileged
  on Android and forbidden on iOS. That capability is deferred to a separate
  capture plugin (below). For the immediate "is the bundled game's audio working"
  question, `adb shell dumpsys media.audio_flinger` (active track + underruns) is
  the answer, no in-app probe needed.
- Both probes observe only the device's own output, never "did a human hear it"
  (that would need a mic loopback, deliberately out of scope).
- Verification idiom is `play → sleep a beat → output_level`; metering is
  instantaneous and only valid while audio plays. The Android `Visualizer`
  occasionally returns its `-96 dB` floor if a measurement window hasn't filled,
  so sample a few times.

## Device verification (moto g power 2021, Android 11) — 2026-06-29

Verified on hardware via `mix mob.connect` dist-RPC into a `doom_demo` build:

- App **boots** with the new NIF table (stable pid) — the boot-critical check for
  a native-table mismatch.
- `output_status/0` → `%{route: :speaker, volume: 0.2, muted: false, other_audio:
  false}`.
- `output_level(:mob)` while a local tone looped → `{-34.8, -31.8}` (real signal);
  idle / after stop → `{:error, :not_playing}`.
- `output_level(:mix)` → `{:error, :unsupported_on_platform}`.
- Without `RECORD_AUDIO` granted at runtime → `{:error, :needs_record_audio}`.
- Disproved the original design: a session-0 `Visualizer` returns `ERROR_NO_INIT`
  even with `RECORD_AUDIO` + `MODIFY_AUDIO_SETTINGS`. This is why `:mix` is
  unsupported in core.

## Follow-up: separate device-audio capture plugin (test-env dependency)

True global/foreign-app output capture on Android is achievable only via
`MediaProjection` + `AudioPlaybackCaptureConfiguration` (API 29+), which pops a
one-time system consent dialog and can capture other apps' output. That UX is
unacceptable in a shipped app but fine in a dev/test harness. Plan: a separate
`mob_*` capture plugin, added as a test-environment dep, exposing a
`capture_level/0`-style probe backed by `AudioPlaybackCapture`. This is where the
"meter Doom's own audio" capability lives. iOS has no equivalent (no
inter-app/system output capture), so that plugin is Android-only. Pairs with the
in-process screenshot work for agent-driven testing, and gives `mob_midi`'s
pending tone primitive something to assert against.
