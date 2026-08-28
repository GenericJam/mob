# The sender: one process owns every render NIF call

- Date: 2026-08-28
- Status: accepted
- Implements: MOB-110, second step of MOB-108
- Builds on: `2026-08-27-screen-process-architecture.md`

## Context

`Mob.Screen.do_render/4` called `Mob.Renderer.render/4` inline, so rendering
happened in whichever process was handling the message. That is safe today only
because there is exactly one screen process. MOB-112 makes screens processes,
and at that point two of them can render at once.

The native contract does not tolerate that. From `ios/mob_nif.m`:

```c
static TapHandle tap_tables[2][MAX_TAP_HANDLES];
static int tap_active = 0;
static int tap_build_count = 0;   // cursor into the BUILDING table
```

`clear_taps` prepares the inactive table and resets the cursor, `register_tap`
appends at `tap_build_count++`, and `set_root` swaps the tables atomically. The
double buffering is explicitly there so a *concurrent reader* — a drag or scroll
event arriving mid-render — resolves against the last committed table. It does
nothing for concurrent *writers*: one global build cursor means two renders in
flight interleave their handles into the same building table, and whichever
reaches `set_root` first commits a table holding both screens' handles while the
other screen's tree is never committed at all.

## Decision

`Mob.Sender` is a named GenServer and the only caller of the render NIFs.
Screens build their tree — which must stay screen-side, since `Mob.Composite`,
`Mob.List`, and `Mob.Component` expansion all take `self()` and register
component pids — and hand the finished tree to `Mob.Sender.render/5`.

`Mob.Renderer` itself uses `self()` nowhere outside doc examples, so the sender
can own the whole `render/4` call. The `{pid, tag}` in each tap comes from the
tree data the screen already baked in, not from the calling process.

### Coalescing, and why it needs the render to be asynchronous

Queuing rather than executing in the caller lets the sender look at what is
waiting: for one screen only the newest tree is committed, and a tree for a
screen that is not active is dropped outright. The second is what lets an
inactive tab hold state without rendering.

### `sync/1` flushes; it does not rely on mailbox order

The first design had `render/5` self-send a `:flush` and `sync/1` merely reply,
on the reasoning that the self-send would already be queued ahead of a later
call. That is wrong, and the tests caught it: `send(self(), :flush)` appends to
the *back* of the mailbox, which is behind a `sync` the caller has already
queued, so `sync/1` returned before the frame was committed.

`sync/1` now performs the flush itself. This also strengthens coalescing — a
burst of renders followed by one `sync` produces a single commit.

### The barrier goes on the call paths only

`Mob.Test` documents `tap/2` and `back/1` as fire-and-forget and its navigation
helpers as synchronous. So `Mob.Screen` calls `Mob.Sender.sync/1` only in the
`handle_call` paths (`dispatch/3` and `{:navigate, _}`), which is exactly where
the documented guarantee lives. The `handle_info` paths stay asynchronous, which
is what leaves anything to coalesce.

### `set_active/1` is a navigation fact, not a render fact

The first cut announced the active screen on every render, which reads as
harmless and is not. Every screen process runs the same `do_render/4`, so at
MOB-112 a *background* screen whose timer fires would promote itself and commit
over the foreground screen — disarming the exact mechanism this step exists to
build. It also guaranteed a fight with MOB-113's router, both writing `active`
with no ownership rule.

`Mob.Sender.set_active/1` is now called only where navigation establishes the
active stack: `Mob.Screen.init/1` and `apply_switch_tab/4`. The router takes
those two call sites over unchanged.

### No render path may run without a sender

Renders are casts, and a cast to an unregistered name is `:ok`. A missing sender
therefore fails in the worst available way: a blank screen, no log, no crash —
until the first synchronous render exits `:noproc`. `Mob.App.start/0` is not the
only boot path (`liveview_notes.md` documents skipping `Mob.App` entirely), so
`Mob.Screen.init/1` calls `Mob.Sender.ensure_started/0` in `:render` mode.

That start is deliberately unlinked. The caller is a screen, and a screen crash
must not take down the process every other screen renders through.

### Coalescing carries the transition forward

Superseding a tree must not silently swallow a navigation animation. A `:push`
rendered from `handle_info` — `forward_to_screen/2`, the back gesture, list
select — could be superseded by an ordinary `:none` re-render from a timer tick
or a component update, and the push would never reach native: correct content,
no animation, intermittently. The transition describes the frame's animation
rather than its content, so a pending non-`:none` transition survives being
superseded; a newer explicit transition still wins.

### `sync/1` gets no deadline from `Mob.Screen`

Rendering was unbounded when it ran inline. `sync/1` is a `GenServer.call`, so
the default 5s timeout would newly turn a slow frame — a large `Mob.List` tree,
a dirty-CPU `set_root` on a loaded device — into a dead screen process.
`Mob.Screen` passes `:infinity`, restoring the previous behaviour exactly.

### A failed render must not kill the sender

`commit/1` rescues. Every screen renders through this one process, so letting it
die on a malformed tree would freeze the entire UI rather than one screen. The
error is logged with a stacktrace.

## Consequences

- `do_render/4` now takes the nav state, because a render has to say which
  screen it is for. The ref is `Mob.Nav.active_ref/1` — the active stack's name,
  or `:__mob_single__` when the app declared no layout. MOB-112 replaces it with
  a per-screen reference.
- `Mob.Screen` is still authoritative about which screen is active and calls
  `set_active/1` on every render. MOB-113's router takes that over; the sender
  already accepts it from anywhere.
- `Mob.Socket.put_root_view/2` now stores `:json_tree` directly. That was always
  the only value `Mob.Renderer.render/4` returned, but the commit is now
  asynchronous so there is no token to wait for.
- Coalescing is not observable in production yet: with one screen process, the
  synchronous call paths flush every render, and the asynchronous ones rarely
  queue two frames. It becomes load-bearing at MOB-112.
- **`Mob.Test` gained `settle/2`.** `:sys.get_state(:mob_screen)` was a
  documented sync point and is no longer sufficient on its own: the screen hands
  its tree to the sender and returns, so a drained screen mailbox does not mean
  the frame is on screen. This only affects the functions that read the *native*
  side (`view_tree/1`, `screenshot/2`, `tap_id/2`, `element_frames/2`);
  `tree/1` and `assigns/1` re-render in-process. `settle/2` drains both.
- **Known gaps, carried into MOB-112 rather than fixed here.**
  `Mob.ComponentRegistry.reconcile/2` still runs screen-side before the cast and
  is destructive — it kills components absent from the new tree — so a tree that
  is then dropped leaves the displayed frame holding handles to dead pids.
  Narrow today; routine at MOB-112, where background renders are *supposed* to
  be dropped, so reconcile has to move to the commit or become non-destructive.
  The sender is also started with a bare `start_link` and no supervisor, matching
  how `Mob.App.start/0` starts every other service, but it is the one process
  whose death silently freezes the whole UI.
- `Mob.Socket.put_root_view/2` is now written even when the commit was dropped
  or raised. The field is read nowhere in `lib/` and predates this change; it
  should be removed rather than made to lie, which is its own change.
- If the sender is not running, renders are silently dropped — `GenServer.cast`
  to an unregistered name is a no-op. `Mob.App.start/0` starts it before
  `on_start/0`, so the only way to hit this is to bypass that entry point.
  `running?/0` exists for a `mix mob.doctor` check.
