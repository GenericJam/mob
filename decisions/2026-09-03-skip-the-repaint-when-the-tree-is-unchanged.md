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

Fingerprint each frame as `phash2({expanded_tree, Mob.Theme.current()})` and
skip the native crossing when it matches the last one committed.

Three things in that sentence were arrived at the hard way.

**The theme has to be in the key.** The first version compared the expanded
tree alone, on the reasoning that `render/1` may read state outside assigns and
running it keeps those inputs honest. That reasoning was wrong, and review
caught it. Token resolution — `:on_background` to ARGB, the font default, the
type scale, spacing, radii — happens in `Mob.Renderer`, **downstream** of this
comparison. A screen written the idiomatic way produces a byte-identical tree
before and after `Mob.Theme.set/1`, so the repaint was skipped and the old
palette stayed on screen. Worse than nothing: `Mob.Theme.set/1` pushes the
resolved palette to native itself, so theme-driven surfaces would follow while
every explicitly-tokened node did not — a half-themed screen. The test that
was supposed to cover this passed only because the fixture baked
`Mob.Theme.current().background` into the tree, which is the one shape real
screens do not use.

**Only `forward/2` may skip.** Every other paint — mount, activation, every
navigation, hot reload, a `:sync` caller — is unconditional. The obvious guard
(`transition != :none`) turns out to guard nothing: the router paints with
`:none` on every push, pop and reset, because the transition rides on the
*activation*, not the paint. And the activation token, which does distinguish
them, is conditional on `activation_frame_supported?/0` — the hot-code-push
fallback. So on that fallback path, popping back to a resident screen whose
tree had not changed would skip its repaint and leave the pushed screen's tree
on display. Restricting the skip to the message path removes the whole class,
and also sidesteps `Mob.Sender` dropping frames for non-active screens: a
background screen's fingerprint may describe a tree that was never committed,
but it cannot act on that, because becoming active goes through the router and
therefore through an unconditional paint.

**A hash, not the tree.** Retaining the expanded tree per live screen roughly
doubles steady-state footprint on a list screen — `Mob.List` materialises a
wrapper plus the rendered row per item — for screens the user cannot see, and
it would be copied across process boundaries by `Mob.Screen.Server.socket/1`,
i.e. over dist on every `Mob.Test.assigns/1`. The trade is a ~1-in-4-billion
chance that two consecutive frames collide and one repaint is skipped; the next
actual change repaints normally.

A skipped repaint is recorded via `Mob.RenderStats.drop_frame/1` as an
uncommitted frame rather than dropped silently, so the meter reports how many
were skipped.

## Consequences

The throttle now works for handlers that live on the screen — the ordinary
case. Measured on the Pixel 8 emulator with both handlers delivered to the
screen and neither assigning:

```
A default 33ms       18 events
B configured 500ms    4 events
```

Against 68 vs 69 for the same shape before.

Nine tests count `set_root` at a stub NIF rather than inferring from the code,
covering both directions: a no-op message, re-assigning the same value, a real
change, a theme change read from outside assigns, and an explicit render or
`:sync` render with an unchanged tree. Three mutations checked, each failing
exactly the tests that should catch it: restoring the unconditional repaint,
letting explicit renders skip, and dropping the theme from the fingerprint.

The fixture deliberately uses `text_color: :on_background` — a token — because
the earlier fixture baked a resolved colour in and made the theme test pass
against an implementation that ignored the theme entirely. A test asserts the
fixture still uses the token.

**What this does not do.** It does not make an unchanged tree free: `render/1`
and the expansion passes still run on every message. Making *those* cheap is a
different change, and the honest place to look next is whether a screen needs
to run `render/1` at all for a message it ignored. It also does not address the
per-frame handle churn itself — handles are still re-registered on every frame
that does paint, which is MOB-124's subject.

## What this does not do

Recorded because each is a render input that lives outside the fingerprint, or
a cost the headline numbers do not show.

* **`render/1` and the expansion passes still run on every message.** Only the
  native crossing is skipped. Whether a screen should run `render/1` at all for
  a message it ignored is a separate question.

* **Per-frame handle churn is untouched.** Handles are still re-registered on
  every frame that does paint; that is MOB-124's subject.

* **The listener pid is not in the key.** `Mob.Renderer.register_handler/2`
  resolves tap targets through `Mob.Listener.handler/1`, a `Process.whereis`.
  If the listener dies and restarts it gets a new pid, the committed tap table
  still names the dead one, and every control on screen is inert. Previously
  the next message repainted and re-registered, self-healing in one message; an
  unchanged tree now never re-registers. Narrow — the listener is started once
  and is not supervised for restart — but it is the same class as the theme bug
  above, and closing the theme half does not close this one.

* **A frame the sender rescued is still recorded as displayed.**
  `Mob.Sender.commit/1` rescues a raising render in the sender process, after
  the screen has already written `last_frame`. Nothing propagates back. Mostly
  benign, since re-rendering the same tree would raise again, but the
  observable change is that `[mob] render failed` now logs once instead of once
  per message — a screen wedged by an unencodable prop goes quiet.

* **Every painting frame pays an extra full tree traversal.** `phash2` over the
  expanded tree runs whether or not the frame is skipped: roughly 70 ns/node
  here, so ~15-150 µs on a 200-2000 node screen. A clear win when it skips,
  pure added cost when it does not.
