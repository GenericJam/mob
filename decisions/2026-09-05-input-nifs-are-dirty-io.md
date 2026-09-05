# Harness input NIFs run on a dirty IO scheduler

Date: 2026-09-05
Status: accepted
Ticket: MOB-160

## Context

Android's default BEAM argv is `-S 1:1 -SDcpu 1:1 -SDio 1 -A 1`
(`android/jni/mob_beam.zig`). One normal scheduler. Whatever blocks it blocks
every process on the device.

Every harness input NIF blocks. They hand work to the platform UI thread and
wait for the answer: Android through a `CountDownLatch` against a main-thread
coroutine, iOS through `dispatch_sync` to the main queue. Until now all of
them except iOS's `tap_xy` were registered with `.flags = 0`.

MOB-160 made this acute rather than theoretical. Android gestures now have to
hold the pointer for their real duration, because the platform's long-press
and drag detectors wait on posted callbacks and frame boundaries and ignore
synthesised timestamps. `long_press_xy(node, x, y, 800)` blocks for 800ms.
iOS was already there and nobody noticed: on the device branch
`nif_long_press_xy` calls `[NSThread sleepForTimeInterval:]` for the caller's
full duration on a normal scheduler. (The simulator branch drives the press
through `_setState:` instead and does not sleep. The device sleep is doubly
wasteful, since per the 2026-08-09 decision that injection path is accepted
and never delivered — it is 800ms of dead time.)

800ms is roughly 800 times the ~1ms budget the Erlang efficiency guide gives a
NIF. For that window the device does nothing at all: no timers, no renders, no
`:rpc`, no PubSub. An agent driving the UI would be pausing the app it is
trying to observe.

## Decision

`tap`, `tap_xy`, `long_press_xy`, `swipe_xy`, `type_text`, `delete_backward`
and `clear_text` are registered `ERL_NIF_DIRTY_JOB_IO_BOUND` on both platforms.
iOS additionally flags `key_press`, `ax_action` and `ax_action_at_xy`.

(There is no `tap_by_label` NIF on either platform — it is a capability atom
and a Kotlin method name; the NIF behind it is `tap/1`.)

The flags diverge by platform because the code does. Android's `key_press` is
a hardcoded `:not_implemented` stub that never touches the UI thread, so a
dirty hop would buy nothing; iOS's `dispatch_sync`s. Android has no
accessibility path at all, while iOS's `nif_ax_action_at_xy` retries its
lookup four times with `[NSThread sleepForTimeInterval:0.05]` between
attempts — up to ~150ms of literal sleep, which is the same bug in a place
nobody was looking.

IO-bound rather than CPU-bound: they are not computing, they are waiting on
another thread, which is what that flag is for. The default argv already
provisions a dirty IO scheduler (`-SDio 1`), so they get a thread that is not
the one running everyone else's processes.

This extends `decisions/2026-08-09-tap-xy-reports-observed-effect.md`, which
moved iOS's `tap_xy` because it blocks for the settle window. That reasoning
was right and was applied too narrowly — Android's copy of `tap_xy` never
followed at all — but it does not simply generalise: only `tap_xy` has a settle
window. What covers the rest is plainer, and was true the whole time: they
block on `dispatch_sync` or on a latch.

The previous note above `nif_funcs[]` in `ios/mob_nif.m` did state a principle,
so this is a reversal rather than a gap. It held that the harness calls these
in tight loops and that dirty-dispatch overhead would add up, pending
benchmarks that were never run. That trade is the wrong way round: the cost is
a thread wakeup per call (real — `-sbwtdio none` means the dirty scheduler
does not busy-wait, so each call pays one), and the thing being traded away is
the whole VM for the duration. We have not measured the wakeup cost, and are
accepting it deliberately rather than claiming it is free.

## Consequences

- A blocking input NIF costs a dirty IO scheduler slot, not the VM.
- There is exactly one dirty IO scheduler (`-SDio 1`), so this converts a
  total stall into head-of-line blocking on a resource of size one. An 800ms
  long press now delays anything else that is IO-dirty — on Android that
  includes `resolve_ipv4` (the DNS path), `audio_output_level` and
  `vendor_usb_bulk_write`; on iOS, `safe_area`, which is on a layout path.
  Strictly better than what it replaces, but it is a new contention edge, and
  the answer if it bites is to raise `-SDio`, not to go back.
- `long_press_xy` still takes its full duration. That is inherent — a long
  press that returns early is not a long press. The call is now merely slow
  rather than globally stalling.
- The rule to apply to anything added here later: **if it waits on the UI
  thread, it is dirty.** The old table had no principle, which is how one
  member of a group of nine ended up flagged correctly and eight did not.
