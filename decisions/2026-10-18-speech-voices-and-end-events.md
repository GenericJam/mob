# Speech voices go through MobBridge; `voices/0` is synchronous; end events are `{:speech, …}` pairs

- Date: 2026-10-18
- Status: accepted

## Context

Bezalel wants users to pick the text-to-speech voice. `Mob.Speech` could only
pass a language tag and said nothing when an utterance ended. Android's
`TextToSpeech` lives in the app's generated `MobBridge.kt`
(`2026-05-27-tts-mob-speech.md`), its voices exist only after the engine's
asynchronous `onInit`, and its completion callbacks need a
`UtteranceProgressListener` subclass.

## Decision

- **Android stays on the bridge** (mob_new template: `ttsSpeakFor`,
  `ttsVoices`), unlike the pure-JNI route of
  `2026-09-11-appexit-native-jni-not-bridge.md`. The engine is the bridge's
  own `tts` instance, and end events need a Java subclass of
  `UtteranceProgressListener`, which JNI cannot create without a dex. Both
  methods are `cacheOptional`; an older bridge keeps speaking through
  `ttsSpeak`, and `voices/0` says `{:error, :unsupported}` rather than `[]`.
- **`voices/0` is synchronous** (dirty NIF; Android's Kotlin waits up to 5 s
  for `onInit` on a latch) rather than a request plus a message. A list is
  what every caller wants, a timeout is rare and becomes `:unavailable`, and
  a message would have needed a new `nativeDeliver*` JNI entry in every app's
  `beam_jni.c`. Callers that mind the wait use `start_async/3`.
- **Native code returns raw quality numbers; Elixir normalises.** Android's
  `Voice.QUALITY_*` (100–500) and iOS's `AVSpeechSynthesisVoiceQuality` (1–3)
  don't overlap, so one table in `Mob.Speech.decode_voices/1` maps both and is
  host-tested, as is the sort.
- **One `:voice` option, id first.** iOS tries `voiceWithIdentifier:`, then
  `voiceWithLanguage:`; Android tries `getVoices()` by name, then
  `Locale.forLanguageTag`. Ids and tags don't collide on iOS. Android ids are
  themselves valid tags (`en-us-x-sfg-local`), so a missing Android id falls
  back to its language's voice, which is closer to the user's choice than
  the default.
- **Events are `{:speech, :done | :cancelled | :failed}` to the caller of
  `speak/3`.** Two-element tuples, so they can't match the `mob_speech`
  plugin's three-element `{:speech, kind, payload}` recognition events, and
  `:failed` rather than `:error` to keep the two apart when read. iOS has no
  failure callback, so `:failed` is Android only.
- **Android options are per utterance.** `speakNow` sets rate, pitch and voice
  (or the default voice) before every `speak`, because the engine keeps them
  between calls and iOS doesn't.

## Consequences

- Android needs mob_new 0.6.14's bridge block and a `TTS_SERVICE` entry in
  the manifest's `<queries>` (missing from the template until then; without
  it API 30+ hides the engine). Existing apps port both by hand.
- After `stop_speaking/1`, Android sends `:cancelled` for every flushed
  utterance and iOS for the one in progress only. Documented, not unified.
- Android voice names are synthesised (`"English (United States) sfg"`);
  the platform has none.
