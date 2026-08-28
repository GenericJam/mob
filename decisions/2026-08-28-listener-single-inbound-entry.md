# The listener: one inbound entry point, without touching native

- Date: 2026-08-28
- Status: accepted
- Implements: MOB-111, third step of MOB-108
- Builds on: `2026-08-27-screen-process-architecture.md`

## Context

`Mob.Renderer` registered interaction handlers by naming a screen process
directly — `nif.register_tap({screen_pid, tag})`, at ~35 call sites, one per
interactive prop. That hard-wires the inbound path to whichever process rendered
the tree. It is also the half of the epic that looked like it would force a
native change, since native is what stores and dispatches those handles.

## Decision

It does not force one. `nif_register_tap` stores an arbitrary term as the
handle's tag (`enif_make_copy` into the handle's own env) and `mob_send_tap` /
`mob_send_event` echo it back verbatim as `{event, tag}`. The tag can therefore
be a nested tuple carrying more than a screen's label.

`Mob.Renderer` now registers

    {listener_pid, {:mob_route, screen_pid, tag}}

Native delivers `{:tap, {:mob_route, screen_pid, tag}}` to `Mob.Listener`, which
forwards `{:tap, tag}` to the screen. The screen sees exactly the message it saw
before. **No `.m`, `.zig` or generator-template change**, which was the epic's
constraint.

### Two shapes, not one

The first cut of this change unwrapped a single shape, `{event, tag}`, on the
assumption that every handle-addressed native event looked alike. It does not,
and the cost of being wrong is invisible: an unmatched envelope reaches the
screen as nothing at all, so the control simply stops working with no crash and
no log.

Native has two families, both reading a tap handle:

* `{event, tag}` — `mob_send_tap`, `mob_send_event`, `mob_send_scrolled_past`:
  `:tap`, `:focus`, `:blur`, `:submit`, `:dismiss`, `:select`.
* `{event, tag, payload}` — `mob_send_change`, `mob_send_compose`,
  `mob_send_swipe_with_direction`, `mob_send_scroll`, `mob_send_drag`,
  `mob_send_pinch`, `mob_send_rotate`, `mob_send_pointer_move`: every text
  field, toggle and slider `on_change`, tab selection (which is wired to
  `mob_send_change_str`), and every gesture stream.

Both are unwrapped on the event atom, so a new event *kind* needs no change
here — but a new *arity* would, which is why anything else carrying a
`{:mob_route, _, _}` is now logged at error rather than discarded. No sender
uses a 4-tuple: every `enif_make_tuple4` in `ios/mob_nif.m` is a NIF return
value, not a message.

### The envelope carries a pid, not a screen ref

The epic sketched `{listener_pid, {screen_ref, tag}}` with the listener
resolving the ref. Carrying the pid needs no registry and no resolution step,
and it produces the behaviour the epic actually asked for: a handle registered
by a screen that has since been stopped delivers to a dead pid, which the BEAM
drops. That is precisely the MOB-107 fix — the event is dropped rather than
delivered into whatever screen happens to be current with that screen's socket.

A ref becomes worth its cost when a screen can be *restarted* and keep its
identity across a new pid, which is MOB-112. The change is confined to
`handler/1` and `handle_info/2`.

### `:mob_screen` is untouched

The other thing native knows is `enif_whereis_pid("mob_screen")` — back gesture,
alert actions, launch-notification fallback, both platforms. That name still
belongs to the screen process. MOB-113's router takes it over; this step
deliberately leaves it alone so the two changes stay separable.

### No listener means no envelope

`handler/1` returns its target unchanged when no listener is running, so events
go straight to the screen exactly as before. That keeps every boot path working
whether or not it starts a listener, and it is why the renderer's existing tests
needed no changes.

## Consequences

- The ~35 call sites now go through one `register_handler/2`. That indirection,
  not the listener itself, is what makes MOB-112 and MOB-113 tractable: the
  inbound path stops naming a screen process in 35 places.
- **The hop buys nothing yet.** With one screen process, carrying its pid
  through the listener and forwarding is pure overhead. It is worth stating
  plainly rather than implying otherwise — the value is entirely in where the
  next two steps get to make their change.
- **The escape hatch is "do not call `handler/1`."** A high-frequency stream
  (drag, scroll, `mob_touch` at display rate) pays one hop and one copy per
  event; registering `{screen_pid, tag}` directly bypasses the listener and
  still works, because that is what the renderer did before. Nothing bypasses it
  today: the hop has not been measured, and carving out an exception before
  there is a number would be guessing.
- `Mob.Event.Bridge` is unaffected. It translates the `{:tap, tag}` a screen
  receives, and the listener unwraps before the screen sees anything.
- The listener is started by `Mob.App.start/0` and, for boot paths that skip it,
  by `Mob.Screen.init/1` — unlinked, for the same reason as `Mob.Sender`: the
  caller is a screen, and a screen crash must not take down the process every
  screen's events arrive through.
- **The native double in the tests has to model both families.** The version
  that modelled only `{event, tag}` produced a passing test asserting that
  `on_change` worked while it was in fact being dropped — worse than no test.
  `FakeNative.fire/3` now replays the 3-tuple senders, and every one of the
  eight has a round-trip test.
- Like the sender, it has no supervisor. Its death is less severe — `handler/1`
  falls back to direct registration on the *next* render — but handles already
  baked with the dead listener's pid go nowhere until then.
