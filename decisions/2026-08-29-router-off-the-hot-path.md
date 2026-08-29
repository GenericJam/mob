# The router: navigation extracted, and kept out of the per-message path

- Date: 2026-08-29
- Status: accepted
- Implements: MOB-113, fifth step of MOB-108
- Builds on: `2026-08-28-screen-processes-and-supervision.md`

## Context

MOB-112 gave `Mob.Screen` a third job. It was already the behaviour screens
implement and the macro that generates their boilerplate; it became the process
owning navigation and every screen process as well. Nearly 1000 lines, and a
moduledoc that had to describe all three — which is part of why that moduledoc
had been wrong twice.

The epic's remaining constraint on that process is sharper than "tidy it up":
the router must **not** be in the per-message path.

## Decision

`Mob.Router` holds navigation, the screen processes, and the `:mob_screen`
registered name. `Mob.Screen` keeps the behaviour and the macro, and delegates
its public API, so `Mob.Screen.dispatch/3` and friends still work.

This is a move, not a redesign — the process model landed in MOB-112 and is
unchanged here.

### The hot-path property already held; this pins it

Tracing the router's mailbox while a screen handles ordinary messages shows it
receives nothing. That is not new — MOB-111's listener already delivers native
events straight to the owning screen's pid, so a tap goes native → listener →
screen → sender with the router uninvolved.

What is new is that it is now **asserted rather than reasoned about**.
`test/mob/router_hot_path_test.exs` traces `:receive` on the router and asserts
the trace is empty.

It covers both halves of the path, which took a change to make possible. The
callback half (`handle_info` into user code) runs under `:no_render`. The render
half — tree expansion, `Mob.ComponentRegistry.reconcile/2`, the hand-off to
`Mob.Sender` — is skipped entirely by `:no_render`, and `:render` needs a NIF.
The first version of this test therefore proved nothing about the half where a
hop is *most* likely to appear: an "am I still active?" check in the render body
is the obvious shape of one. A router hop added to `paint/3` passed the whole
suite.

`Mob.Screen.Server` now takes its NIF module as an option, defaulting to
`:mob_nif`. That is not test-only scaffolding — `Mob.Renderer` and `Mob.Sender`
already take it as a parameter, and the screen was the outlier that hardcoded
it. With a stub NIF the test drives real renders off-device, and negative
controls confirm both halves bite: a hop in `forward/2` fails the callback
tests, a hop in `paint/3` fails the render tests.

This matters more than a tidy-up. An earlier costing of this architecture
assumed a router in the loop and concluded per-screen processes could not escape
a hop per message. Splitting the router from the sender is what dissolved that,
and a property that load-bearing should fail loudly when someone breaks it —
not be rediscovered by reading the code.

### What still goes through the router, deliberately

* navigation actions a screen produces (`{:nav_action, …}`)
* the back gesture, alert actions, and launch notifications, which native
  addresses to `:mob_screen`
* device events and plugin messages sent to `:mob_screen`, forwarded to the
  active screen
* `Mob.Screen.dispatch/3`, the programmatic entry point used by tests and
  tooling

None is a per-message path for a running screen. The last two are the ones to
watch: they make the router a shared serialisation point, which is MOB-121.

## Consequences

- `Mob.Screen` drops from ~995 lines to ~230, and its moduledoc describes one
  thing.
- `decode_file_result/3` stopped being a `@doc false` public function on the
  owner and became private to `Mob.Screen.Server`, its only caller.
- Two guides were making claims that were aspirational before MOB-112 and are
  now nearly true; they now say what actually happens. `screen_lifecycle.md`
  claimed each screen was "a separate, supervised process" — separate is now
  right, supervised is still not: the router restarts screens itself because
  only it knows where a crashed one sat.
- The `:mob_screen` name still belongs to the router, so no native change and no
  generator-template change. The epic said the router would take that name over;
  it already had it under a different module name.
