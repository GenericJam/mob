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

### Screens are unlinked and monitored, not linked

The first cut used `start_link`, and the tests caught it immediately: the owner
stops a popped screen with `GenServer.stop(pid, :shutdown)`, the link
propagated that exit to the owner, and the owner died — taking navigation and
every sibling screen with it. Exactly the coupling this step exists to remove,
reintroduced by the mechanism meant to manage it.

Screens are started with `GenServer.start/2` and monitored. The owner observes
every exit without sharing its fate, and its `terminate/2` stops the screens it
owns so each gets its own `terminate/2` and final state dump.

### Not a DynamicSupervisor

A supervisor restarting a screen would produce a process the owner knows
nothing about, in a slot the supervisor cannot know — the crashed screen might
be the current one, in the active stack's history, or parked under an inactive
tab, and restoring it means putting the new pid back exactly where the old one
was. The owner is the only thing that knows that, so it owns the restart. This
is the "deliberate restart strategy" MOB-112 asks for.

The cost: a screen orphans if the owner is killed without running `terminate/2`
(`Process.exit(owner, :kill)`). Acceptable — the owner dying means the app is
going down — but a `DynamicSupervisor` under a real supervision tree would
close it, and mob does not have one yet.

### A crash must not come back up a call

`Mob.Screen.dispatch/3` is a call on the owner, which calls the screen. A crash
in `handle_event` exits that inner call, which would have killed the owner —
defeating the isolation on the one path MOB-112's acceptance names explicitly.
Every owner-to-screen call goes through `safe_call/1`, which catches the exit
and lets the monitor repair the screen.

### A restart re-mounts, and says so

A restarted screen runs `mount/3` again and loses its assigns; persisted
screens get their dumped state back through `load_state/2`. This is logged at
error, because it is visible to the user — a form clears, a list resets — and
silently losing state is worse than saying why.

Background screens (in the active stack's history, or parked under another
stack) are re-mounted eagerly rather than lazily. A crash is rare, and keeping
every nav entry a live pid means popping or switching back never has to handle
a corpse.

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
  mid-crash. Callers of `get_socket/1` in that window see `nil`; the monitor
  repairs the screen immediately after.
