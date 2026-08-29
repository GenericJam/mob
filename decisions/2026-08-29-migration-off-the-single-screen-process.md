# Migration: the surface that assumed one screen process

- Date: 2026-08-29
- Status: accepted
- Implements: MOB-114, final step of MOB-108
- Builds on: `2026-08-28-screen-processes-and-supervision.md`,
  `2026-08-29-router-off-the-hot-path.md`

## Context

MOB-114 was scoped as three pieces of migration work: `Mob.Test`'s direct
`:mob_screen` calls, `dump_state`/`load_state` spanning processes, and
`__mob_hot_reload__` becoming a broadcast.

Two of the three were already done when this step started. They fell out of
MOB-112 rather than needing separate work: each live screen schedules its own
state sync and dumps in its own `terminate/2`, and hot reload has been a
broadcast over `all_entries/1` since screens became processes.

Neither had a test. That is the real gap — behaviour that arrived as a side
effect of another change, asserted nowhere.

## Decision

### `Mob.Test` keeps addressing `:mob_screen`

The third piece was attempted and **reverted**, which is the more useful thing
to record.

`tap/2`, `select/3` and `send_message/2` were changed to resolve the screen pid
and send to it directly, on the reasoning that a native tap reaches a screen via
`Mob.Listener` without touching the router, so the harness should too. Review
showed that reasoning was wrong on three counts:

* **It made the thing it was avoiding worse.** `Mob.Screen.get_screen_pid/1` is
  a `GenServer.call` into the router — the same serialisation point the change
  cited as its motivation. It replaced one asynchronous send through the
  router's mailbox with a synchronous round-trip into it, plus a second send.
  Measured at **5002 ms** for one `send_message` while the router was blocked in
  a call to a screen, against a documented fire-and-forget contract.
* **Resolve-then-send is not atomic.** The router's forward reads
  `state.current.pid` and delivers in one step. Resolving separately opens a
  window — a full RPC round trip, tens of milliseconds over a tunnel — in which
  the screen can be restarted and the event delivered to a corpse. Proved: kill
  the screen between resolve and send and the message is lost, where addressing
  `:mob_screen` delivers it to the live replacement.
* **The premise was factually wrong.** Native delivers tap-handle events to the
  screen, but alert actions go to `:mob_screen` on both platforms
  (`ios/mob_nif.m`, `android/jni/mob_nif.zig`), and webview messages do on iOS
  unconditionally and on Android whenever no explicit pid was registered. Those
  are documented `send_message/2` payloads. Router-handled shapes stopped working
  entirely: `send_message(node, {:mob, :back})` no longer popped, because the
  screen's default `handle_info` swallowed it.

Addressing `:mob_screen` is correct, and not merely the status quo: the router
resolves and delivers atomically, in one non-blocking RPC, and it is where
native itself sends the messages this function is documented to simulate.

`back/1` and `navigate/2` were always right for the same reason.

### The two behaviours that arrived for free are now pinned

`test/mob/screen/migration_test.exs` asserts that hot reload repaints a screen
in a parked stack's history *and* that stack's current screen, not just the one
on screen; and that a screen in history persists and restores its own assigns.

Both verified as negative controls: reverting hot reload to a single cast, or
removing the dump from `Mob.Screen.Server.terminate/2`, fails exactly the tests
written for them. Before MOB-112 the second was not merely untested but
impossible — only the active screen held a socket.

### Two barriers that looked like barriers and were not

Worth recording, because both produced a passing test that proved nothing.

`Mob.Sender.sync/1` is not a barrier for hot reload. A background screen's tree
is *dropped* rather than committed, so the sender catching up says nothing about
whether that screen processed its cast. Neither is `:sys.get_state(router)`:
`hot_reload/1` is a cast per screen, so draining the router proves only that the
casts were sent. The screens themselves have to be drained — and because
`render/1` is user code that may take arbitrarily long, the assertion is a
bounded wait rather than a snapshot comparison. With a 30 ms sleep in `render/1`
the snapshot version failed every run; the bounded version passes.

Screens dump in their own `terminate/2`, which runs *after* the router exits, so
`GenServer.stop(router)` returning does not mean the writes have landed. The
state tests monitor the screens and wait for their exits — otherwise the dump
races `start_supervised!(Repo)`'s teardown and logs a DB error out of a passing
test.

## Consequences

- **Ordering weakened from total to per-screen, and nothing depended on it.**
  Audited: on any *message* path the only multi-screen iteration in `lib/` is the
  hot-reload broadcast, where each screen repaints independently and only the
  active one's tree is committed. (`handle_call(:get_nav_history, …)` also walks
  every history entry, but it is a debugging API rather than an event path, and
  it only reads.) The `Enum.reduce(discarded, …, &stop_screen/2)`
  calls in `pop_to_root`, `pop_to` and `reset` are sequential but
  order-independent — each entry is stopped in isolation.
- `Mob.Test` is unchanged by this step. The epic listed its seven `:mob_screen`
  call sites as migration work; the conclusion is that they were already right.
