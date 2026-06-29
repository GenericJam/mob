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
  - `:mix` (default) — taps the **global output mix**, so it observes audio from
    native players that bypass `Mob.Audio` (the Doom case). Android: `Visualizer`
    on session 0 (needs `RECORD_AUDIO`). iOS: unsupported (sandbox forbids a
    global-mix tap) → `{:error, :unsupported_on_platform}`.
  - `:mob` — taps only `Mob.Audio`'s own player. iOS: `AVAudioPlayer` metering
    (free, no permission). Android: reads the global mix (same path as `:mix`).

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

- **Honest asymmetry:** for audio that bypasses `Mob.Audio` (Doom-style), level-2
  works on Android (global-mix tap, costs `RECORD_AUDIO`) but **not** on iOS
  (level-1 only). Documented in the moduledoc rather than papered over.
- Both probes observe only the device's own output, never system-wide capture of
  other apps — correct for "is the audio mob/this app is producing working,"
  not "did a human hear it" (that would need a mic loopback, deliberately out of
  scope).
- Verification idiom is `play → sleep a beat → output_level`, since metering is
  instantaneous and only valid while audio plays.
- **Device verification is the gate** (host `mix test` can't exercise native): a
  native-table mismatch is a silent boot-time crash, so confirm the app still
  boots, then that `output_level(source: :mix)` reads non-silent during playback
  and `:silent` otherwise. The Android `Visualizer` one-shot (create → enable →
  60 ms settle → measure → release) is the part most worth confirming on real
  hardware.
- Follow-up: pairs with the in-process screenshot work for agent-driven testing,
  and gives `mob_midi`'s pending tone primitive something to assert against.
