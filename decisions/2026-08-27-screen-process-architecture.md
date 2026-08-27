# Screen process architecture: router, per-screen processes, listener, sender

- Date: 2026-08-27
- Status: accepted (direction) — implementation staged, tracked in Linear

## Context

Today one `Mob.Screen` GenServer, registered as `:mob_screen`, owns everything.
Its state is `{module, socket, nav_history, render_mode}`, and `apply_nav_action/3`
swaps that tuple in place on push/pop/reset. There is exactly one active screen,
one navigation history, and one mailbox.

Four separate problems trace back to that single tuple.

**1. Async results are delivered to the wrong screen.** `forward_to_screen/2`
hands any unmatched message to `module.handle_info(message, socket)` where
`module` is whatever screen is active *now*. A task started by screen A that
completes after navigating to B is not merely late — it is delivered into B's
`handle_info` with B's socket. If A and B use the same message shape
(`{:loaded, data}` is the obvious one) B silently processes A's payload. And
`use Mob.Screen` generates `def handle_info(_message, socket), do: {:noreply, socket}`,
so an unmatched stale result vanishes with no log and no crash. Reported by
@minibikini, who works around it with a user-space wrapper correlating every
result by task ref plus entity context.

**2. `tab_bar/1` is declared but unrepresentable.** `Mob.App.tab_bar([stack(:home,
root: HomeScreen), stack(:settings, ...)])` appears in `Mob.App`'s own moduledoc
as the recommended iOS shape. `Nav.Registry.register_nav/1` flattens the branches
into a flat ETS table of `{name, root, %{}}` — it records that each stack exists
and nothing more. With one `nav_history` list, two tabs cannot each own a live
stack. Tabs are the canonical case of simultaneous screens on both platforms
(UITabBarController, Android bottom nav; SwiftUI's `TabView` demonstrably keeps
every tab's subtree mounted and its `@State` alive across switches). `drawer/1`
has the same shape and the same gap. iPad split view, multi-scene / Stage Manager,
and a sheet presented over a still-live parent are the same class.

**3. The docs promise isolation we do not deliver.** The `Mob.Screen` moduledoc
has claimed "Each screen runs as a supervised GenServer... a buggy `handle_event`
crashes its own screen and the supervisor restarts it without taking down
navigation." That is false — a crash takes down every screen, the whole stack,
and navigation with it. Corrected by mob#76, but the correction documents a
capability gap rather than closing it.

**4. Transition overlap has already caused a real bug.** During a push, both
screens are on screen and rendering for the duration of the animation. That is
exactly what produced the MOB-103 frame-registry race, where the outgoing screen
kept firing geometry callbacks after its ids had been purged.

An earlier framing treated "multiple simultaneous screens" and "one process per
screen" as the same choice. They are separable: N screens can live in one process
by making the state a map keyed by stack. Processes buy isolation, a meaningful
`terminate/2`, and natural `self()` semantics — not multiplicity.

## Decision

Move to four process roles.

**Router** — owns the navigation stacks (plural), decides which screen is active,
starts and stops screen processes, monitors them. Keeps the `:mob_screen`
registered name so the native layer is unaffected. Critically, it is **not** in
the per-message hot path: a screen handling an ordinary message never touches the
router. The router hears only about navigation.

**Screen processes** — one per live screen, each owning its own socket and
supervised independently. `self()` inside a screen becomes the screen's own pid,
which is what user code already assumes it means.

**Listener** — the single process the native layer sends inbound events to. Fans
out to the router or to a specific screen.

**Sender** — the single process permitted to call the native render NIFs.

### Why the sender must be a single process

This is forced by the existing native contract, not by taste. `ios/mob_nif.m:93-97`:

```c
static TapHandle tap_tables[2][MAX_TAP_HANDLES];   // MAX_TAP_HANDLES 256
static int tap_active = 0;
static int tap_build_count = 0;   // cursor into the BUILDING table
```

`register_tap` appends into the inactive table at `tap_build_count++`;
`nif_set_root` swaps atomically (`tap_active = 1 - tap_active`,
`tap_handle_next = tap_build_count`) and resets the cursor. It is a
build-then-commit protocol with **one global build cursor**. Two screens
rendering concurrently would interleave their `register_tap` calls into the same
build table, and whichever reached `set_root` first would commit a table
containing both screens' handles while the other screen's tree was never
committed. Rendering must therefore be serialized through exactly one process.

Coalescing then falls out as a feature: the sender commits only the active
screen's tree and drops superseded ones, which is precisely what inactive tabs
need — state alive, no rendering.

### Why the native layer does not change

Native knows two things only: `enif_whereis_pid("mob_screen")` (back gesture,
alert actions, launch-notification fallback — both platforms) and explicit pids
stored in tap handles.

The first is satisfied by the router keeping the registered name. For the second,
`Mob.Renderer` currently emits `nif.register_tap({pid, tag})` (`renderer.ex:344`);
registering `{listener_pid, {screen_ref, tag}}` instead means native delivers
`{:tap, {screen_ref, tag}}` to the listener, which unwraps and forwards
`{:tap, tag}` to the owning screen. Native remains ignorant of screens entirely.
No `.m`, `.zig` or template change is required to move to this architecture.

### What this subsumes

Problem 1 stops existing rather than being filtered. A task started by screen A
sends to A's pid: if A was popped and stopped, the BEAM drops the message; if A
is alive in another tab, A handles it and its state is current when you switch
back — better than dropping. A tagging scheme (`{module, generation}` correlated
in `handle_info`) was considered as a narrower fix and would work, but it is
opt-in, cannot protect untagged messages (timers, native events, plugin
messages), and becomes dead code once screens are processes. It remains the
right stopgap if this architecture is deferred.

## Consequences

- **Ordering weakens from total to per-screen.** Nothing is known to depend on
  cross-screen ordering, but nav-versus-render interleaving is exactly why the
  sender stays single.
- **Pop keeps processes resident.** Today pop restores a cheap `{module, socket}`
  snapshot. Preserving "restores prior state without re-mounting" means keeping
  the stack's processes alive — more memory, but it matches how iOS and Android
  actually behave.
- **Crash isolation needs deliberate wiring**: restart strategy, router monitors,
  and the sender being told to re-render after a restart. A restarted screen
  re-mounts and loses its assigns; that is what the moduledoc already promises,
  and it should be stated explicitly rather than implied.
- **High-frequency inbound streams get an extra hop.** Drag, scroll and
  `mob_touch` at display rate pay one listener hop and one copy per event. The
  mechanism supports registering a screen pid directly to bypass the listener;
  keep that escape hatch and measure before optimising.
- **Migration surface**: `Mob.Test` has seven direct `:mob_screen` calls
  (`get_state`, tap/back/select/message sends, `navigate`, generic call);
  `dump_state`/`load_state` must span multiple processes; `__mob_hot_reload__`
  becomes a broadcast rather than one cast.
- **`terminate/2` becomes meaningful** for the first time, which closes the
  documentation gap mob#76 had to write around.
- Multi-stack state (the router owning `%{stack => history}`) is independently
  valuable and can land before per-screen processes. It is what makes `tab_bar/1`
  representable, and it is required at every level of this design.
