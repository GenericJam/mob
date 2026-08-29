# Screen processes: one per screen, owned and monitored rather than supervised

- Date: 2026-08-28
- Status: accepted
- Implements: MOB-112, fourth step of MOB-108
- Builds on: `2026-08-27-screen-process-architecture.md`

## Context

One `Mob.Screen` process held `{module, socket, nav, render_mode}` and swapped
the first two in place on navigation. Every screen shared one mailbox, so a
crash in any `handle_event` took down navigation and every other screen with
it. `Mob.Screen`'s moduledoc claimed the opposite for a long time; mob#76
corrected the docs, which documented the gap rather than closing it.

## Decision

`Mob.Screen.Server` is one process per live screen, owning that screen's
socket. `Mob.Screen` becomes the owner: it holds the navigation state, starts
and stops screens, and keeps the `:mob_screen` registered name so the native
layer's `enif_whereis_pid` lookups are unaffected.

The owner's state is the same shape it was — `{module, socket, nav,
render_mode}` — with the socket replaced by the pid of the process that now
owns it. `Mob.Nav` needed no change to hold pids: it always treated entries as
opaque.

### Screens are linked, and everyone traps exits

This took two wrong turns worth recording, because each fix created the next
problem.

Linking alone is wrong: the owner stops a popped screen with
`GenServer.stop(pid, :shutdown)`, the link propagates that exit, and the owner
dies — taking navigation and every sibling with it. Exactly the coupling this
step removes, reintroduced by the mechanism meant to manage it.

Unlinking (`GenServer.start/2` plus a monitor) fixes that and is also wrong: it
orphans every screen when the owner dies. That is not hypothetical — an
orphaned screen keeps its 30s `Mob.ScreenState` timer and dumps under the same
`screen_key` as its live replacement, so orphans overwrite live persisted
state.

The answer is both: screens are **linked**, and the owner **traps exits**. The
owner sees each exit as an `{:EXIT, pid, reason}` message without sharing its
fate, and screens still come down with it. Screens trap too, so gen_server
turns the owner's exit into a `terminate/2` call — which is what runs the
user's `terminate/2` and the final state dump.

Two consequences fall out:

* The owner's `terminate/2` deliberately does **not** stop screens. Calling
  `GenServer.stop/3` there corrupts the owner's own exit: the screen's
  `:shutdown` travels back up the link while the owner is mid-terminate and
  replaces its reason, so a clean `stop(owner, :normal)` exits `:shutdown`.
  Letting the link do the work is both simpler and correct.
* A *deliberate* stop (popping a screen) unlinks first, for the same reason —
  we are discarding that screen, so its exit must not reflect back.

### Every owner-to-screen call is protected

`safe_call/1` wraps all of them, not most. Two were missed in the first cut and
both were fatal: `handle_call(:inspect)` pattern-matched `{:ok, socket}`, so the
one case `safe_call` exists for raised a `MatchError` *inside the owner*; and
`paint_sync` was a raw `GenServer.call`, so a crash in the user's `render/1` —
reached by the everyday "tap a button that pushes a screen" path — exited the
owner. Both defeated the isolation on paths more common than the
`handle_event` crash the tests covered.

### Not a DynamicSupervisor

A supervisor restarting a screen would produce a process the owner knows
nothing about, in a slot the supervisor cannot know — the crashed screen might
be the current one, in the active stack's history, or parked under an inactive
tab, and restoring it means putting the new pid back exactly where the old one
was. The owner is the only thing that knows that, so it owns the restart. This
is the "deliberate restart strategy" MOB-112 asks for.

An earlier draft of this file claimed the cost was orphaning on
`Process.exit(owner, :kill)`. That is wrong: `:killed` is a trappable reason for
the *linked screens*, so each still runs `terminate/2` and its final dump.

The real cost is the restart ceiling a supervisor would have given for free.
The owner carries its own (`@max_restarts` in `@restart_window_ms`, per screen
ref) because without it a screen that mounts cleanly and crashes on every render
loops at roughly 6500 restarts a second, writing a log line each time. The other
gap is a screen wedged in a callback: the owner's bounded `GenServer.stop/3`
kills it outright on timeout rather than leaving it unlinked and untracked but
alive, still dumping to `Mob.ScreenState` under the same key as its
replacement.

### A crash must not come back up a call

`Mob.Screen.dispatch/3` is a call on the owner, which calls the screen. A crash
in `handle_event` exits that inner call, which would have killed the owner —
defeating the isolation on the one path MOB-112's acceptance names explicitly.
Every owner-to-screen call goes through `safe_call/1`, which catches the exit
and lets the monitor repair the screen.

### A navigation entry carries what a restart needs

An entry is `%{module:, pid:, params:, ref:}`, not `{module, pid}`. The params
and ref are not bookkeeping — a restart is wrong without them:

* A screen that mounts on `%{id: id}` cannot come back from `%{}`. The re-mount
  raises, the restart fails, and the owner is left holding a dead pid as
  `current` — every later event calls a corpse and returns `:ok`, so the app
  freezes silently.
* A screen parked under an inactive stack must keep *that stack's* render ref.
  Restarting it with the active ref means its next repaint commits over the
  foreground tab, undoing the drop-inactive mechanism MOB-110 built.

### A restart re-mounts, and says so

A restarted screen runs `mount/3` again and loses its assigns; persisted
screens get their dumped state back through `load_state/2`. Logged at error,
because it is visible to the user — a form clears, a list resets — and silently
losing state is worse than saying why.

When the re-mount itself fails, the owner does not leave the corpse in place:
a background screen is dropped from its stack, and a current screen pops to
whatever is beneath it. With nothing beneath, it logs that the app has no live
screen rather than pretending otherwise.

Background screens are re-mounted eagerly rather than lazily. A crash is rare,
and keeping every nav entry a live pid means popping or switching back never
has to handle a corpse.

### A no-op navigation still paints

The screen deliberately does not paint when it produced a nav action, so every
branch of `apply_nav_action/3` that changes nothing has to paint instead —
`:noop` switch_tab, `pop` at root, `pop_to` not found, and each `start_screen`
failure. Without that, `socket |> assign(:x, v) |> switch_tab(:home)` while
already on `:home` updates the assigns and never renders them. Re-tapping the
active tab is the everyday case, not an exotic one.

### Mutate navigation only after the mount succeeds

`switch_tab`'s `mount_root` starts the screen before touching `nav` or the
sender's active ref. Doing it the other way round leaves the sender addressing
a stack whose screen never started, so every frame the live screen produces is
dropped — a silent freeze — while nav holds the same pid in two places.

### Owner-to-screen calls have no deadline

`dispatch/3` and `render_sync/2` pass `:infinity`. The screen returns its nav
action *in the reply*, having already cleared it from its socket, so a timeout
does not fail the event — it silently discards the navigation the user asked
for. A slow `handle_event` is a slow app; it is not a lost push. A deliberate
stop does have a bound, so one wedged screen cannot block teardown forever.

### Popping stops the screen; the ones below stay resident

The screen leaving the stack is destroyed with it. The screens still in the
history stay alive, which is what makes pop restore prior state without
re-mounting — and what the epic's ADR called out as the memory cost of matching
how iOS and Android actually behave.

Demonitoring before stopping matters: without it, the shutdown the owner asked
for returns as a `:DOWN` and the screen is "restarted" immediately after being
deliberately discarded.

### The screen hands navigation to the owner and does not paint

A callback that sets a nav action has it delivered to the owner, and the screen
does **not** render. Painting there would flash the outgoing screen's tree for a
frame before the navigation replaced it — the same class of overlap that
produced the MOB-103 frame-registry race.

Two paths, because two guarantees differ. `dispatch/3` is synchronous, so the
screen *returns* the action and the owner applies it before replying. A nav
action from `handle_info` is *sent*, matching the fire-and-forget semantics
`Mob.Test` documents for taps.

Only the active screen may drive navigation. A background screen's timer must
not yank the stack out from under what the user is looking at.

## Consequences

- **`self()` inside a screen is now the screen's own pid.** This is what user
  code always assumed when writing `on_tap: {self(), :save}` or starting a
  task, and it is what stops screen A's task result being delivered into screen
  B's `handle_info` with B's socket (MOB-107).
- Public API is unchanged: `dispatch/3`, `get_socket/1`, `get_current_module/1`
  and `get_nav_history/1` all keep their shapes, with the owner fetching
  sockets from the screen processes to preserve `[{module, socket}]`.
- `get_screen_pid/1` is added, because tooling now needs a way to reach the
  process actually holding the screen.
- `__mob_hot_reload__` became a broadcast: every live screen repaints with the
  new code, not just the one on screen.
- Anything else addressed to `:mob_screen` — device events, notifications,
  plugin messages — is forwarded by the owner to the active screen.
- An owner-to-screen call returns `nil` rather than raising when the screen is
  mid-crash. `get_socket/1` and `Mob.Test.assigns/1` document and handle that.
- **`Mob.Test.settle/2` now drains three processes, not two.** `:mob_screen` is
  the navigation owner; it forwards to the screen, which builds the tree, which
  the sender commits. Draining only the owner proved nothing — every
  `tap -> settle -> screenshot` sequence in the agent workflow would have been
  newly racy.
