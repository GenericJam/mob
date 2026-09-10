# A safe-area read with no window is not an answer

Date: 2026-09-10
Status: accepted
Ticket: MOB-166 (with mob_new #63)

## Context

`nif_safe_area` finds the active window through `connectedScenes` and reads its
`safeAreaInsets`. When it finds no window it returned zeros, which is
indistinguishable from a device that genuinely has none — an iPad, or an older
iPhone.

`Mob.Screen.Server.ensure_safe_area/3` stopped asking as soon as the
`:safe_area` assign existed. So the first reading a screen took was the reading
it kept for life.

Those two behaviours are only compatible while the BEAM cannot start before a
window exists. That was true when the boot lived in `scene:willConnectToSession:`
after `makeKeyAndVisible`. It stops being true as soon as anything boots
earlier, and two ordinary things do:

* a **background launch** connects no window scene at all — the case mob_new #63
  exists to handle;
* an **iOS 15+ prewarmed launch** runs `application:didFinishLaunchingWithOptions:`
  well before the user taps the icon, and prewarming is routine.

A screen that painted in that window would be under-padded until it was
replaced — at the bottom and sides specifically, since `MobRootView` already
ignores the container's safe area on those edges while respecting the top. UIKit usually wins the race, which is what makes
it the bad kind of bug: rare, silent, and permanent for the screen it hits.

This was found by the pre-commit review of mob_new #63, whose first version
booted unconditionally from `didFinishLaunchingWithOptions:` and would have made
the race the common case rather than a rare one.

## Decision

**The NIF distinguishes "no window" from "no insets."** `nif_safe_area` returns
the atom `:no_window` when it cannot find a window, instead of a zeroed tuple.

**A placeholder is assigned but not trusted.** The `:safe_area` assign is still
always present — screens are documented to read `assigns.safe_area` directly, and
a missing key would be a `KeyError` inside `render/1`, which is a worse failure
than wrong insets. It holds zeros, and the socket records that the reading is
unconfirmed. `ensure_safe_area/3` asks again on each paint until the platform
gives a real answer, then stops.

Stopping matters: each read is a hop to the main thread, and re-reading every
paint would trade a rare layout bug for a permanent per-frame cost.

**But a confirmed answer is not permanent, and an earlier draft of this record
claimed it was.** Insets change under a screen — rotation, a resized scene —
which `decisions/2026-08-28-multi-stack-nav-state.md` had already recorded. So
the confirmation is *invalidated* rather than final: `mob_notify_window_connected()`
sends `{:mob_window, :connected}` from `scene:willConnectToSession:`, and
`Mob.Screen.Server` clears the flag and repaints.

That hook is also what makes the placeholder case actually work. `ensure_safe_area/3`
is only reached from a paint, and **nothing repaints when a scene connects** —
so on a prewarmed launch the screen would paint its placeholder, then sit until
the user interacted, showing a wrong first frame. Re-reading on paint is not a
fix on its own; something has to cause the paint.

## Consequences

- Android does not consult a window, so it never answers `:no_window` — but its
  reply now goes through the same `case`, which has a catch-all: Android answers
  `:error` when it cannot attach to the JVM, and without that clause a screen
  would die in `init/1` with a `CaseClauseError` instead of degrading to zeros
  and retrying.
- The contract of `mob_nif:safe_area/0` changed from "always a 4-tuple" to "a
  4-tuple or `:no_window`". Both callers are in `Mob.Screen.Server`. Test stubs
  returning a 4-tuple are unaffected.
- Requires a native rebuild to take effect (`mix mob.deploy --native`) — the
  Elixir half degrades safely without it, since a 4-tuple is still handled.
- The guarantee documented in `guides/screen_lifecycle.md` — that the socket
  always has a `:safe_area` assign — is preserved deliberately, and the guide now
  says what happens before the platform can answer.
- The regression test asserts the *second* paint, not the first. An earlier
  version of it asserted only the boot-time value and passed with the fix
  reverted, because `init` never marked its own reading confirmed either way.
  Checked by reverting: treating `:no_window` as confirmed fails it.

## Verified on device

An app generated from the paired `mob_new` branch, built native against this
branch (both `mob.exs`'s `mob_dir` and `mix.exs`'s dep pointed at the same
checkout, so the two halves could not diverge), deployed to a simulator and
inspected over dist:

- `:mob_screen` resolves to the router — the registered name
  `mob_notify_window_connected()` looks up via `enif_whereis_pid`, so the native
  sender has a real target.
- The screen holds **real** insets, `%{top: 20.0, bottom: 25.0, left: 0.0,
  right: 0.0}`, with `__mob__.safe_area_confirmed == true`. Not the zeroed
  placeholder, on a build that boots from `didFinishLaunchingWithOptions:`.
- Sending `{:mob_window, :connected}` — the exact term the native function
  sends — leaves the app alive and still on its screen, so the new handler is
  reached and does not disturb a screen that is already correct.

**Not verified:** a launch that genuinely paints before the window — a real
prewarm or background launch. Forcing one needs a background mode and a real
trigger. The unit tests cover the state machine for that case; the device check
covers the ordinary path and the native plumbing.

