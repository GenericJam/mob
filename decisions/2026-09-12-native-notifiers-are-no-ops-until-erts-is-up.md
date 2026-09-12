# Native notifiers are no-ops until erts is up

- Date: 2026-09-12
- Status: accepted
- Issue: MOB-199 (regression from MOB-166)

## Context

The native shell tells the BEAM about things UIKit knows first: the window
scene connected, the colour scheme flipped. Those notifiers are plain C
functions in `mob_nif.m` that build a message with `enif_alloc_env` and
`enif_send`. MOB-166 moved the window notification into the generated
`SceneDelegate` and called it before `mob_boot_runtime()`, with a comment
saying it was a no-op when the runtime was not up. It was not: `enif_*` is
only defined behaviour after `erl_start` has initialised erts, and on a
physical iPhone the call jumped through a null allocator pointer. iOS
reports that as `EXC_BAD_ACCESS` at `0x0` with a `CODESIGNING` termination
and no BEAM output at all. The simulator did not fault, the deploy task
reported a restart over a dead process, and every 0.5.x-generated app was
dead on physical iOS.

## Decision

`mob_nif.m` keeps an atomic `g_runtime_up`, set at the end of `nif_load`
(the first code the BEAM runs in this file, so erts is fully initialised by
then) and read through `mob_runtime_up/0` declared in `mob_beam.h`. Every
notifier the shell can fire from a UIKit callback returns early while it is
false. The window-connected notification is only needed by a screen that
painted before the scene connected, and the boot path reads the window's
insets itself, so dropping it before boot loses nothing.

The alternative, ordering the SceneDelegate so the boot precedes the
notification, was rejected: `willConnectToSession:` can fire more than
once per process and the ordering comment already existed and was wrong;
the guard belongs at the callee, where the invariant lives.

## Consequences

- Any new `mob_notify_*` entry point reachable from UIKit must check
  `mob_runtime_up()` first. Senders driven by the BEAM's own render tree
  (taps, changes, gestures) cannot fire before the BEAM drew the tree and
  need no guard.
- A deploy that reports "Apps restarted" is not evidence the app is running;
  the crash reports under `systemCrashLogs` and an empty
  `Documents/beam_stdout.log` are the tell. Worth a check in `mix mob.deploy`
  for physical iOS (follow-up).
