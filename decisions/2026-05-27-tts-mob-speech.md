# Text-to-speech ships as a core NIF (Mob.Speech), not a plugin

- Date: 2026-05-27
- Status: accepted

## Context

Apps (e.g. an offline docs reader) want to read text aloud. iOS and Android
both ship a system TTS engine (`AVSpeechSynthesizer` / `TextToSpeech`), but mob
had no wrapper. The plugin system that will eventually host optional native
capabilities is still phase-0 (design docs + stubs), so there's no in-lane way
to ship TTS as a plugin yet.

## Decision

Add `Mob.Speech` as a **core capability NIF**, mirroring the existing
`Mob.Camera` / `Mob.Clipboard` / `Mob.Audio` pattern:

- `Mob.Speech.speak/3` + `stop_speaking/1` — socket-threading like `Mob.Haptic`;
  options (`rate`/`pitch`/`voice`) whitelisted and `:json.encode`d.
- NIFs `tts_speak/2` + `tts_stop/0` (`src/mob_nif.erl`), implemented in
  `ios/mob_nif.m` (AVSpeechSynthesizer, lazy persistent synth) and
  `android/jni/mob_nif.zig` → `MobBridge.ttsSpeak` (generated Kotlin in mob_new).

Notable sub-decisions:

- **Android bridge methods are `cacheOptional`, not `cacheRequired`.** Apps
  generated before TTS lack `ttsSpeak`/`ttsStop` in their `MobBridge.kt`; a
  required cache lookup would fail `on_load` and purge the *entire* NIF library.
  Optional caching + a `Bridge.tts_* == null` guard means those apps simply
  no-op TTS until regenerated, rather than breaking.
- **`TextToSpeech` initializes asynchronously** (an `OnInitListener`), so the
  Kotlin keeps one engine alive and queues the first utterance until `onInit`.
- **`rate`/`pitch` are platform-scaled, not normalized.** iOS `rate` is 0–1,
  Android `setSpeechRate` centers on 1.0 (~0.5–2.0). Documented as
  "platform-scaled"; a normalization layer can come later if needed.
- STT is **not** included — deferred (still a plugin candidate; see the surface
  matrix).

## Consequences

- One blessed `Mob.Speech` API; TTS now shows ✅ in the capability matrix.
- New native capabilities follow this full path: Elixir module + `mob_nif.erl`
  (export/`-nifs`/clause, covered by `nif_stub_test`) + `ios/mob_nif.m` (+ funcs
  table) + `android/jni/mob_nif.zig` (struct field + impl + `cacheOptional` +
  funcs table) + a `MobBridge.kt.eex` method in mob_new.
- Device-verified end-to-end on both platforms before merge (Android audible,
  iOS screen + AVSpeechSynthesizer path). When the plugin system lands, TTS
  could migrate out of core — revisit then.
