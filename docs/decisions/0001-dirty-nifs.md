# 0001 — Dirty NIF scheduling for `mob_nif`

**Status**: Accepted (2026-04-28)
**Scope**: `ios/mob_nif.m`, `android/jni/mob_nif.c`

## Context

Until 2026-04-28, every entry in the iOS and Android `nif_funcs[]` tables used
flag `0` — i.e. all ~60 NIFs ran on regular schedulers. Two patterns were
mixed in that single bucket:

1. **Dispatch-and-return** (the majority). A NIF wraps `dispatch_async` to the
   main UI queue and returns in microseconds. Trivially safe on a regular
   scheduler.

2. **Synchronous BEAM-thread CPU work**. Four NIFs do real CPU on the BEAM
   thread before any dispatch, or `dispatch_sync` and walk a recursive object
   graph while holding the main queue. With flag `0`, the regular scheduler
   thread is blocked for as long as the NIF runs — which can be 10s of ms
   for a complex screen.

The `1ms` rule for regular NIFs (Erlang efficiency guide) was being violated
intermittently for the second category. Symptoms would be sporadic latency
spikes on whichever Erlang process happens to share the scheduler with a
busy `set_root` call.

## Decision

Mark the four CPU-heavy NIFs as `ERL_NIF_DIRTY_JOB_CPU_BOUND`:

| NIF | Why dirty CPU |
|---|---|
| `set_root/1` | `NSJSONSerialization` parse + recursive `MobNode` tree construction on the BEAM thread, *before* any dispatch. Scales with render-tree size. Called every render. |
| `set_transition/1` | Same call pattern as `set_root`; sibling. |
| `ui_tree/0` | `dispatch_sync` to main queue + recursive `walk_a11y` over the entire `UIApplication` window graph. Variable cost; can be many ms on a screen with hundreds of accessibility elements. |
| `ui_debug/0` | Same walk as `ui_tree`, more output. |

Everything else stays on regular schedulers, including:

- **All synthetic-input NIFs** (`tap`, `tap_xy`, `swipe_xy`, `long_press_xy`,
  `type_text`, `key_press`, `delete_backward`, `clear_text`). They `dispatch_sync`
  to the main queue but do little BEAM-thread work. The test harness fires
  these in tight loops; dirty-dispatch overhead (~3–10 µs/call) would
  accumulate. Re-evaluate if benchmarks ever show the regular scheduler
  stalling under heavy harness use.
- **Property queries** (`battery_level`, `safe_area`, `device_*`, `clipboard_get`,
  `platform`, `webview_can_go_back`). Read a single property and return.
- **Fire-and-forget UI** (`haptic`, `share_text`, `alert_show`, `toast_show`,
  `audio_play`, `camera_capture_*`, etc.). `dispatch_async` + return.
- **Bookkeeping** (`register_tap`, `clear_taps`, `register_component`,
  `deregister_component`, `log`, `set_dispatcher`). Mutex + struct fields.

## Risks and mitigations

1. **Dispatch overhead** (~3–10 µs/call). Negligible vs the multi-millisecond
   work the marked NIFs do. Not measurable for the unmarked ones.

2. **Dirty CPU scheduler count under Nerves tuning**. We default to `-S 1:1`,
   so OTP runs **one** dirty CPU scheduler. Concurrent `set_root` calls (e.g.
   from two screens re-rendering) serialize. Mitigation: bump
   `+SDcpu 2` (or whatever) via `mix mob.deploy --beam-flags "..."` if it
   shows up in profiles. Has not been observed to date.

3. **Thread locality**. Dirty NIFs run on different OS threads than regular
   NIFs. mob's NIFs use proper mutexes (`tap_mutex`, `component_mutex`) and
   `dispatch_sync` to the OS main queue, both scheduler-agnostic. No code
   secretly assumes "next NIF runs on the same thread as me".

4. **Reverting**. Trivial — change the flag back to `0` in the relevant
   `nif_funcs[]` row. No state migration, no rebuild of unrelated code.

## How to extend the decision

If you're tempted to add `ERL_NIF_DIRTY_JOB_*` to a new NIF, use this checklist:

1. **Profile first.** Use the Erlang VM's scheduler-stall reports (`+swt very_high`)
   or wallclock-time logging to confirm the NIF actually does enough work to
   matter. Many NIFs that *look* heavy are actually `dispatch_async` + return
   in single-digit microseconds.
2. **Pick the right kind.** `CPU_BOUND` for real computation on the BEAM
   thread. `IO_BOUND` for waiting on another thread (e.g. blocking
   `dispatch_sync` to a busy main queue).
3. **Keep this list updated.** If you add a new dirty NIF, append it to the
   table above and to the inline comment block in the corresponding
   `nif_funcs[]`.
4. **Watch the dispatch overhead.** Dirty scheduling adds a few µs per call.
   For NIFs called at video frame rate, it can be net-negative.

## See also

- `ios/mob_nif.m` — search for "Scheduling notes" above the iOS `nif_funcs[]`
- `android/jni/mob_nif.c` — search for "Scheduling notes" above the Android
  `nif_funcs[]`
- Erlang efficiency guide — [Dirty NIFs](https://www.erlang.org/doc/system/nif.html#dirty-nifs)
