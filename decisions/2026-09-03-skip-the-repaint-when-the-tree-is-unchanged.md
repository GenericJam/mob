# Skip the repaint when the rendered tree is unchanged

- Date: 2026-09-03
- Status: accepted
- Part of: MOB-124
- Related: `2026-09-02-throttle-config-targets-the-building-table.md`

## Context

`Mob.Screen.Server.forward/2` ended every `handle_info` with an unconditional
repaint:

```elixir
{:noreply, %{state | socket: paint(state, :none)}}
```

No comparison against the previous state. **Any** message to a screen triggered
a full render: walk the tree, `clear_taps`, a `register_tap` per interactive
node, serialise, `set_root`, rebuild the native tree. A handler that changed
nothing cost exactly as much as one that changed everything, so a 30 Hz scroll
handler drove 30 full renders per second.

It also fed a feedback loop. Each render calls `clear_taps`, which zeroes the
per-handle throttle state including `last_emit_ns`; `throttleCheck` treats
`last_emit_ns == 0` as "no previous emission" and emits unconditionally. **The
native throttle was defeated by the very events it was throttling.** MOB-134
measured this directly: the same two handlers, one default and one
`throttle: 500`, gave 68 vs 69 events when delivered to the screen and 33 vs 5
when delivered to a plain process. The only difference was whether the
handler's own delivery caused a repaint.

## Decision

Compare the expanded tree against the last one committed, and skip the native
crossing when they are equal.

**Compare the tree, not the assigns.** Assign comparison is the LiveView model
and would be cheaper, but it is wrong here: `render/1` in this framework may
legitimately read state that is not in assigns. `Mob.Theme.set/1` is the
obvious one — a handler that changes the theme without assigning anything must
still repaint, and an assigns-based check would leave the old theme on screen.
Running `render/1` and comparing its output keeps every such input honest.

It still removes the expensive half. Per MOB-124's own measurements the native
crossing dominates; `render` + expand are Elixir-side and comparatively cheap.

The tree is comparable across frames because handles are assigned later, inside
`Mob.Renderer`. At the comparison point interactive nodes still carry their
`{pid, tag}`, which is stable for the life of a screen.

Three cases always paint, regardless: a navigation (the transition is the
point, and the native side keys view identity on it), an activation token
(it has to reach native), and a `:sync` caller (it is waiting on a flush).

A skipped repaint is recorded via `Mob.RenderStats.drop_frame/1` as an
uncommitted frame rather than dropped silently, so the meter says how many
repaints were skipped.

## Consequences

The throttle now works for handlers that live on the screen — the ordinary
case. Measured on the Pixel 8 emulator with both handlers delivered to the
screen and neither assigning:

```
A default 33ms       18 events
B configured 500ms    4 events
```

Against 68 vs 69 for the same shape before.

Six tests count `set_root` at a stub NIF rather than inferring from the code,
and cover both directions: a no-op message, re-assigning the same value, a real
change, and a change `render/1` reads from outside assigns. Mutation-checked —
restoring the unconditional repaint fails exactly the three "must not repaint"
tests and leaves the three "must repaint" ones passing.

**What this does not do.** It does not make an unchanged tree free: `render/1`
and the expansion passes still run on every message. Making *those* cheap is a
different change, and the honest place to look next is whether a screen needs
to run `render/1` at all for a message it ignored. It also does not address the
per-frame handle churn itself — handles are still re-registered on every frame
that does paint, which is MOB-124's subject.
