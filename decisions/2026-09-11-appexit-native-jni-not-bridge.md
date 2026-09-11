# Android ApplicationExitInfo ingest goes through pure JNI, not MobBridge.kt

- Date: 2026-09-11
- Status: accepted

## Context

MOB-180 adds Android's post-mortem ingest — `ApplicationExitInfo` from
`ActivityManager.getHistoricalProcessExitReasons` — to
`Mob.PostMortem.Android`. There are two conventional routes:

1. **Via the `MobBridge.kt.eex` template.** Add a `@JvmStatic
   postMortemDrain()` to the template that mob_new emits into every
   app. The Zig NIF looks it up via `Bridge.post_mortem_drain` in the
   cached method-ID struct and calls it, matching the pattern for
   `ui_tree`, `screenshot`, `audio_start_recording`, etc.
2. **Pure JNI dynamic class lookup.** The NIF resolves
   `android.app.ActivityManager` and `ApplicationExitInfo` via
   `FindClass` at drain time, walks the returned `java.util.List`
   directly, and never touches `MobBridge`.

Both work. Route 1 is the codebase's default for platform-API
integration; route 2 is uncommon but not unprecedented.

## Decision

Route 2 — pure JNI. `nif_post_mortem_android_drain` in
`android/jni/mob_nif.zig` uses `g_activity` (the global Activity ref
captured by `mob_beam.zig` at BEAM boot) to reach a Context, then
does the class + method lookups against Android's platform APIs
directly.

## Consequences

**Why not the MobBridge template.** `MobBridge.kt` is app-owned and
never regenerated (per `project_mob_plugin_permissions_host_drift`
memory: "the trap is app-owned MobBridge.kt / MainActivity drift
until refreshed"). A template addition benefits only newly-generated
apps. Every existing mob app would silently return `[]` on drift —
exactly the wrong shape for a passive framework observability feature
that promises to watch every user's crashes. `MobPostMortem.sweep/0`
saying "no crashes since last boot" when the framework hasn't
actually asked the OS would train a triager to distrust the channel.

Pure JNI works on every app the moment they bump mob. No template
change, no `mix mob.doctor` refresh dance, no
`feedback_widen_dep_across_lockstep_minor`-shaped conversation.

**Cost accepted: ~250 lines of Zig JNI.** More code than a bridge
method + short caller would be. Trades line count for the guarantee
that the feature actually runs.

**API-30+ only.** `getHistoricalProcessExitReasons` is Android 11+.
The NIF caches `Build.VERSION.SDK_INT` and returns `[]` on older
devices. The Elixir side additionally gates on `platform() ==
:android`, so a caller on iOS or in a host test does zero JNI work.

**Persistent marker on disk, not in SharedPreferences.** The NIF
writes `<filesDir>/mob_post_mortem_appexit_marker.txt` via POSIX
`open`+`write`+`close`. SharedPreferences would need more JNI dance
(getSharedPreferences → SharedPreferences.Editor → putLong →
commit); the marker holds a single integer so a text file is enough.
Any I/O failure is silent: the worst outcome is a re-emit of
already-emitted entries on next boot, which the Registry then dedups
within the current BEAM session.

**Trace inclusion deferred.** `ApplicationExitInfo.getTraceInputStream()`
returns the raw trace file for an ANR — potentially KB of stack text
with app strings mixed in. That needs the same
`Mob.Agent.Receipt.summarize_error/3`-style discipline the receipt
module already documents before it can safely reach the bus. Not in
this phase; a follow-up ticket if the plain reason-code proves
insufficient for triage.

**Fingerprint groups aggressively.** The fingerprint key is
`(kind + process_name + reason_code)` — so two ANRs of the same
class in the same process across boots become one triage row. If
`process_name` is empty (an OS quirk seen occasionally) two
unrelated ANRs would collapse; the mitigation is that
`Mob.PostMortem.Android`'s `valid_shape?` gate requires
`process_name` to be present, and the OS reliably provides it for
every observed entry. If field data ever shows otherwise, tighten
the key by adding the top-frame from the trace file when phase-2
trace inclusion lands.
