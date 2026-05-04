# BEAM crash log + mitigation strategy

Working log of BEAM crashes seen on Mob apps in development, what
caused them, and what mitigations are in place (or planned). Stability
is a feature — every silent BEAM exit is a moment a new user might
walk away. We track them all here.

---

## Categories

- **port** — port-in-use / EPMD / dist conflicts when two devices or two
  app instances try to register at the same time. Should be auto-recovered
  in native code (bump the port, restart).
- **adb / xcrun coordination** — multiple deploys in flight at the same
  time stepping on each other (file locks, signing race, etc.). Mostly a
  developer-tooling issue, not a runtime BEAM issue, but it can manifest
  as a crash on launch if a deploy lands mid-run.
- **on_start** — the app's `on_start/0` callback raises before the screen
  mounts. Process exits cleanly with code 1, no `**` error report visible
  in logcat unless stdio is captured.
- **native NIF mismatch** — a NIF was rebuilt against a different ABI
  than what the device runtime expects.
- **strip-induced** — slim-release dropped a module the runtime actually
  loads at startup (gives a clear `:undef` in IEx if you can connect).
- **SELinux denial** — Android's untrusted_app SELinux profile blocks
  some path the Erlang runtime tries to access (e.g. `erts_dios_1`
  reading `/`, `erl_child_setup` searching `tests/`). Each denial alone
  is benign but cascades have killed BEAMs in the past.

---

## Mitigation strategy (in-flight)

The goal is **users never see a silent black-screen-then-die**. Every
crash should either be auto-recovered or surface a useful message.

### Auto-recover

- **Port-bump-and-restart** on EPMD / dist conflicts — when iOS sim
  port 9101 is already in use (another sim, or a stale process),
  `mob_beam.m` should bump to 9102+ and try again before reporting
  failure. Same on Android (`MainActivity.java` reads
  `mob_dist_port` from intent — needs to attempt bind, fall back).
  - **Status**: Not yet implemented. Sketch in `mitigations/port_bump.md` (TODO).

### Surface

- **Capture BEAM stderr to logcat / iOS console.** Today
  `__android_log_print` only carries `LOGI`/`LOGE` from `mob_beam.c`
  itself; the Erlang runtime writes to stderr which is silently
  discarded on Android. A `dup2` of fd 2 to a pipe + reader thread
  would surface the actual `** Generic server ... terminating` lines
  the BEAM normally prints.
  - **Status**: Not yet implemented. Tracked in
    [Incident #1](#incident-1-android-beam-exits-cleanly-with-code-1-after-on_start)
    below.
- **`mob_set_startup_error(...)` already exists** — it just needs more
  hookpoints. Currently fires on "BEAM exited unexpectedly". Should
  also fire on first-render failure, NIF load failure, distribution
  bind failure.
- **Diagnose-on-blank-screen** — when the native side waits >2 seconds
  for the first render and gets nothing, it should grab whatever the
  startup error is and present it inline (not just splash forever).

### Prevent

- **Slim-release verification** — `mix mob.verify_strip` (in
  mob_dev) eager-loads every shipped `.beam` against a connected
  device. Run it after slim builds before publishing.
- **Port allocation by index** in `mob_dev/lib/mob_dev/tunnel.ex`
  already prevents two devices from being assigned the same dist
  port at deploy time. The runtime auto-recover above is the safety
  net for the case where ports leaked from prior runs.

---

## Incidents

### Incident #1 — Android: BEAM exits cleanly with code 1 after on_start

**Date:** 2026-05-04
**Device:** sdk_gphone64_arm64 emulator (Android 15)
**App:** SquareTriangle (square_triangle)

**Symptom:** App launches, splash screen disappears, brief black
screen (~1.5s), then process dies and Android returns to home screen.
No native crash, no logcat error from `AndroidRuntime` or `libc` —
process exits cleanly with code 1.

**Logcat sequence:**

```
I MobBeam : mob_start_beam: starting BEAM with module=square_triangle, argc=37
I MobNIF  : nif_load: entered, Bridge.cls=0x2e46
I MobNIF  : nif_load: MobBridge.getColorScheme() not found — color_scheme/0 returns :light
E MobNIF  : nif_load: openUrl(String) not found on MobBridge
[~280 ms gap, no further app output]
W erts_dios_1: avc: denied { read } for name="/" dev="dm-0" tcontext=u:object_r:rootfs:s0 tclass=dir
W erl_child_setup: avc: denied { search } for name="tests" tcontext=u:object_r:shell_test_data_file:s0 tclass=dir   (×4)
I ActivityManager: Process com.example.square_triangle (pid 18573) has died: fg TOP
I Zygote: Process 18573 exited cleanly (1)
```

**Same Elixir code on iOS simulator works fine.** Triangle widget
renders, save-to-history flows work, theme tokens resolve. So the
defect is Android-runtime-specific, not a screen/render bug.

**What we ruled out:**

- Native crash — no `AndroidRuntime` `FATAL EXCEPTION`, no
  `tombstoned` entry, no SIGSEGV in libc.
- ecto_sqlite3 NIF load — `mob_start_beam` symlinks
  `libsqlite3_nif.so` and the NIF load message would appear if it
  failed.
- JSON encoding of unknown color tokens (`:surface_outline` in the
  Triangle widget) — same encoding path runs on iOS and works there.
- Compose render exception — no `Compose Runtime` error in logcat,
  and the symptom is *process death*, not a Compose composition fault
  (which would leave the process alive).

**What we suspect (in order of likelihood):**

1. The exit-clean-with-1 pattern is the BEAM calling `erlang:halt(1)`
   after a fatal startup error in the boot script — typically an
   application's `start/2` callback returning `{:error, ...}`.
   `Application.ensure_all_started(:ecto_sqlite3)` in
   `SquareTriangle.App.on_start/0` is the prime suspect because it's
   the one thing the Android runtime path differs on (different
   filesystem layout, different NIF loader).
2. The SELinux `denied { search }` for `tests/` may be the BEAM
   trying to enumerate code paths during `:application.start/2` and
   failing with `:eaccess` somewhere unhandled.
3. A migration in `Ecto.Migrator.run/3` is failing because the
   migrations directory is unreadable on Android (different from the
   `MOB_BEAMS_DIR/priv/repo/migrations` path that's expected).

**Mitigation that would have surfaced this faster:**

- BEAM stderr → logcat (see "Surface" above). Without it we have to
  guess at the root cause from negative evidence.

**Next investigation step:**

- Wire BEAM stderr to logcat via `dup2(pipe[1], STDERR_FILENO)` plus
  a reader thread inside `mob_init_bridge` in
  `android/jni/mob_beam.c`. That's the fastest way to see whatever
  `:application.start/2` is actually returning.
- Once we have the stderr line, fix is likely a one-line config
  change (or a missing migration path).

**Status:** FIXED on the SquareTriangle side; broader mitigation
TODO. Diagnosis log:

1. Wired `dup2` on `STDERR_FILENO` to a pipe in `mob_init_bridge`,
   spawning a reader thread that emits each line under the
   `BEAMout` logcat tag (`mob/android/jni/mob_beam.c`). Without this
   the Android BEAM is silent on Erlang-side errors.
2. With BEAMout in place, the next launch surfaced:

       Runtime terminating during boot (
         {undef,
          [{mob_nif,log,["step 1 starting"],[]},
           {square_triangle,step,2,[{file,"src/square_triangle.erl"},{line,16}]},
           ...]})

3. Looked confusing because the on-device `mob_nif.beam` does
   export `log/1` (verified via `beam_lib:chunks` after pulling the
   file). The `:undef` was a load-vs-call distinction: `mob_nif`
   was technically loaded but `on_load` had failed, which makes
   Erlang silently unload the module again. Every subsequent call
   gets `:undef`.
4. `mob_nif:init/0` calls `erlang:load_nif/2`, which invokes the C
   `nif_load` callback in `android/jni/mob_nif.c`. That callback
   walks ~30 `GetStaticMethodID` calls into the Java MobBridge
   class and `return -1` on the first one missing.
5. Logcat already showed the smoking gun:

       E MobNIF : nif_load: openUrl(String) not found on MobBridge

   The generated SquareTriangle's `MobBridge.kt` was missing
   `openUrl` because the project was scaffolded from a `mob_new`
   template version before that method was added.
6. **Fix:** added `openUrl(String)` to
   `square_triangle/android/.../MobBridge.kt`. BEAM boots, screen
   renders.

**Lesson + broader mitigation TODO:**

`nif_load` returning -1 on a missing optional Java method is the
wrong default. Apps generated against older `mob_new` templates
will silently break every time we add a new Bridge method to
mob_nif.c. The `getColorScheme` precedent in the same file
(`LOGI` + `ExceptionClear` + continue) is the right pattern.

**Plan:** demote `haptic`, `clipboardPut`, `clipboardGet`,
`shareText`, `openUrl`, and the rest of the feature-gated methods
to optional. Keep `setRootJson`, `getSafeArea`, `moveToBack`
required (no app boots without them). At each NIF call site that
uses an optional method, check for `Bridge.X == NULL` and return
`:error_no_native_impl` so Elixir code can handle the absence
gracefully.

Tracked separately as `mitigations/nif_load_optional_methods.md`
(TODO).

---

## Adding a new incident

Append a new `### Incident #N` section. Include:

- date, device, app
- symptom (what the user sees)
- logcat / IEx sequence (raw)
- what was ruled out
- what we suspect
- mitigation that would have helped
- next investigation step
- status (OPEN / FIXED / WONTFIX)

Don't delete fixed incidents — they're the institutional memory
that keeps us from re-doing the same investigation in 6 months.
