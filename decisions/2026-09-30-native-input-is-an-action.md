# Native input is an action: receipted, traced, and never lost silently

- Date: 2026-09-30
- Status: accepted
- Tickets: MOB-305, MOB-306
- Amends: `2026-09-10-a-receipt-per-action-not-a-window.md`,
  `2026-08-28-listener-single-inbound-entry.md`

## Context

On a Moto G (Android 15), driven by real taps through `adb`:

**MOB-305: a real tap was invisible to both observers.** Native input reaches a
screen as the legacy tuples the NIF sends — `{:tap, tag}`, `{:change, tag,
value}`, `{event, tag}`, `{event, tag, payload}` — through `Mob.Listener`, which
forwards them to the screen's `handle_info/2`. Receipts (MOB-155) were recorded
only around `handle_call({:event, ...})`, i.e. `Mob.Screen.dispatch/3`, and
`Mob.Event.Trace.broadcast/3` ran only inside `Mob.Event.dispatch/4`. Nothing on
the native path calls either. A tap that changed state left no receipt, and a
trace subscriber saw zero events. Meanwhile the `Mob.Event` moduledoc said every
emitter goes through `emit/4`, and `guides/agentic_coding.md`'s standard loop was
`Mob.Test.tap/2` — which sends `{:tap, tag}`, the native shape — followed by
`Mob.Agent.Receipts.recent(1)`, showing a receipt with `event: "increment"` that
could never have existed.

**MOB-306: a tap on a crashed screen vanished.** After a handler crash
`Mob.Router` restarts the screen under a new pid. Until native commits the
replacement's tree, taps are still routed to the old pid, and `send/2` to a dead
pid is a silent no-op. Traced: the listener received `{:tap, :increment}` for a
pid with `Process.alive?/1` false; no receipt, no log, and the app's counter
did not move.

## Decision

**A discrete native input is an action, observed where it lands.**
`Mob.Screen.Server.handle_info/2` records a receipt around the user's
`handle_info/2` with the same observed stages as the event path — `:dispatched`,
`:handled`, `:assigns_changed`, `:navigation_requested`, `:frame_changed`,
`:committed`, `:unobservable`, and on a raise an `error` summary written before
the exception propagates. It reuses `build_receipt`/`record_receipt`; the
handler is `{module, :handle_info, 2}`. Two differences are deliberate:

- **No `:unhandled` of its own.** `use Mob.Screen` injects a `handle_info/2`
  catch-all and apps write their own, so there is no "no clause matched" signal
  to observe. A tap the screen ignores is `:inert`. Inventing one — a sentinel
  return, a clause-count heuristic — would be a reported stage, not an observed
  one.
- **`:committed` is conditional.** A forwarded message repaints through
  `repaint_if_changed/1`, which skips an identical frame. The event path's rule
  ("a paint that happened always handed a frame over") does not hold there, so
  `:committed` is reached exactly when the frame changed.

**Every native input, discrete or stream, is traced when the screen receives
it**, with its canonical address and payload, as `dispatch/4` already does. Only
legacy shapes: a `{:mob_event, ...}` envelope was traced by `dispatch/4` as it
was sent, and tracing it again on arrival would report every such event twice.
With no tracers the cost is the same empty `:persistent_term` read as
`dispatch/4`; the address is built only when someone is listening.

**The allow-list lives in one module, `Mob.Event.NativeInput`,** used by the
screen and by the listener:

| Kind | Messages | Receipt | Trace |
|---|---|---|---|
| discrete | `:tap` (list-row select included), `:focus`, `:blur`, `:submit`, `:select`, `:dismiss`, `:long_press`, `:double_tap`, `:swipe_*`, `{:swipe, tag, dir}`, a non-float `:change` | yes | yes |
| stream | `:scroll`, `:drag`, `:pinch`, `:rotate`, `:pointer_move`, `:compose`, a float `:change`, the scroll lifecycle (`:scroll_began`, `:scroll_ended`, `:scroll_settled`, `:top_reached`, `:scrolled_past`) | no | yes |

Receipts are bounded at 256. A stream fires at display rate, or several times per
gesture, so receipting it would evict the tap an agent is about to ask about and
add an assigns comparison and an ETS write per frame. A float `:change` is a
slider: `mob_send_change_float` is the only native sender of a float, SwiftUI
fires it on every step of a drag, and unlike the gesture senders neither NIF
throttles it. Text, toggle and tab changes stay discrete — one per keystroke or
flip is the rate a person acts at. The scroll lifecycle events are single-fire
but come several to a gesture and are consequences of a stream, not something
an agent drives.

**A receipt names an input by address and never carries its payload.** `event`
is `{event_atom, %Mob.Event.Address{}}`, from
`Mob.Event.Bridge.legacy_to_canonical/3` where the Bridge models the shape, and
from the same rule with an implied widget kind (`:text_field` for focus, blur,
submit; `:sheet` for dismiss; `:button` otherwise) where it does not. A
`:change` takes its widget from the value's type — a boolean is a `:toggle`, a
binary a `:text_field` — because the Bridge calls every change a text field,
and on the Moto G a `<Toggle>` flip was receipted as one; the Bridge's own
documented default is left alone. Only the type is read. The
payload is dropped because a text field's value is what the user typed, and a
receipt is written to ETS and handed to telemetry — MOB-155's rule that a
receipt carries nothing out of the socket, extended to what came in. A tag that
is not a valid address id (`nil`, a pid, a ref, a fun) is `{event, :opaque}`,
not the term. The listener's log line uses the same payload-free name.

**An input for a dead local screen is recorded, not delivered.** The listener
checks `Process.alive?/1` for a local target before forwarding. Every such event
bumps a counter, surfaced as `Mob.Diag.health().listener.undeliverable`; a
discrete one also gets a receipt with the single stage `:undeliverable`,
`screen: nil`, `owner/1` → `:event_routing` and `effect/1` → `:undeliverable`;
and the first event for each dead pid is logged. It is still not forwarded to
the replacement screen, which may be showing something else — that is MOB-107's
misrouting.

## Alternatives rejected

- **Route native input through `Mob.Event.dispatch/4`.** It would trace for
  free, but it changes what every screen's `handle_info/2` receives from
  `{:tap, tag}` to `{:mob_event, ...}` — a breaking change to every app, to fix
  an observability gap.
- **Record the receipt in the listener.** The listener cannot see assigns, the
  frame or navigation, so it could only record `:dispatched`. The stages are the
  point of a receipt.
- **Extend `legacy_to_canonical/3` to model focus, blur, submit, dismiss and
  the gestures.** Screens that use the Bridge's documented pattern fall back to
  their legacy clauses on `:passthrough`; turning those shapes into envelopes
  would silently bypass handlers apps already have. The implied-widget rule is
  private to `NativeInput`.
- **Receipt streams too, or sample them.** A sampled receipt answers no
  question about a specific action; an unsampled one floods the store.
- **Put the counter in a `Mob.Diag.Store`.** There is no table to own: one
  `:counters` cell in `:persistent_term`, created by the listener on first use,
  survives listener restarts and is read by `health/0` without a call into the
  process carrying every screen's input. AGENTS.md rule 17 is about tables.

## Consequences

- An agent's loop — `Mob.Test.tap/2`, `settle/2`, `Mob.Agent.Receipts.recent/1` —
  now reads the receipt for the tap it drove. `Mob.Test.select/3` sends the
  native row-tap shape `{:tap, {:list, id, :select, index}}` instead of the
  already-converted `{:select, id, index}`, so it takes the same path as a
  finger; `handle_info/2` still receives `{:select, id, index}`.
- Cost, measured on the host (Apple silicon, 1M iterations): classifying a
  message ~1 ns over the loop baseline; classify plus the no-tracer trace check
  ~20 ns per stream event; naming a discrete input for its receipt ~60 ns; the
  listener's liveness check ~3 ns per event. Non-input messages pay one
  function-head match.
- The liveness check is a race, not a guarantee: a screen that dies between
  the check and the `send` still loses the event silently. A remote target pid
  cannot be checked and is forwarded as before.
- Not traced: an opaque tag (it has no address), input that never reaches a
  screen, and ordinary `handle_info/2` messages. An app that sends itself
  `{:tap, tag}` gets a receipt for it, exactly as `Mob.Test.tap/2` does.
- Still no receipt for a `render/1` that raises, on either path: the paint runs
  outside the `try`.
- This does not fix why native keeps routing to a dead screen after a restart;
  it makes each such event visible and counted.
- Verified on the host (rung 2), each test failing with its fix reverted or
  mutated: `test/mob/agent/native_input_receipts_test.exs` (tap verified and
  inert without a false `:committed`, raising tap, payload-free change,
  opaque tag, list-row select, stream traced not receipted, single trace for a
  dispatched envelope) and `test/mob/listener_test.exs` (undeliverable receipt
  and counter; one payload-free log line, streams counted not receipted). Not
  re-run on a device.
