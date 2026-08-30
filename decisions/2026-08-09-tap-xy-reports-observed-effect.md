# tap_xy reports observed effect, not API acceptance

- Date: 2026-08-09
- Status: accepted

## Context

`mob_nif:tap_xy/2` returned `ok` whenever the platform input mechanism did not
raise an error. That is not the same as "the tap worked", and the gap is wide:

- **iOS simulator** — the branch activates the accessibility element under the
  point. SwiftUI only maps `accessibilityActivate` to a default action for
  `Button`-like views. Mob's `Box` / `Row` / `Column` implement `on_tap:` with a
  plain `.onTapGesture`, which has no accessibility *action*, so activation is
  accepted, the handler never runs, and `tap_xy` still answered `ok`. (Since
  #94 a `Box` given `accessibility_role: "button"` does collapse into a real
  AX element with the `.isButton` trait — but it still carries no
  `accessibilityAction`, and activating it verifiably does not fire the
  gesture, so the outcome is unchanged: `{error, no_effect}`.)
- **iOS physical device** (iPhone, iOS 26.5.2) — the branch synthesises an
  `IOHIDEvent` and asks `mob_send_touch_phase` whether it worked.
  `mob_send_touch_phase` returns `YES` as soon as
  `IOHIDEventCreateDigitizerFingerEvent` resolves and `_handleHIDEvent:` exists,
  i.e. it reports *API availability*, never delivery. Every coordinate returned
  `ok`, including coordinates with nothing tappable under them, and nothing
  happened for any of them.

The damage is not the broken tap — it's the false `ok`. An agent or a test
driving a device cannot distinguish a working tap from a no-op, so failures read
as passes. An iOS renderer bug sat unverified in a downstream repo for weeks
because of exactly this.

## Decision

`ok` now means **the app demonstrably reacted**, on both iOS paths.

A process-wide counter (`g_ui_event_seq` in `ios/mob_nif.m`) is bumped by every
send helper that routes a user-originated event into the BEAM — `mob_send_tap`,
`mob_send_event` (focus / blur / submit / select) and `mob_send_change`.
`nif_tap_xy` samples it before injecting, then polls for up to
`MOB_TAP_SETTLE_MS` (300ms) after. It also hit-tests up front on *both* paths;
previously only the device path did.

Return contract:

| Value | Meaning |
|---|---|
| `ok` | An event reached the BEAM within 300ms. |
| `{error, no_view_at_point}` | Hit-test found nothing — outside every visible window. |
| `{error, no_element_at_point}` | Simulator: a view is there, no AX element to activate. |
| `{error, no_effect}` | The OS accepted the input; no handler ran. |
| `{error, Probe}` | Device: the private injection API is missing. |

`tap_xy` moves to `ERL_NIF_DIRTY_JOB_IO_BOUND` — it can now block for the settle
window, which is far too long for a normal scheduler. (It already slept 100ms on
the device path, so this also fixes a pre-existing scheduler violation.)

Chose observation over "just document the limitation" (option b in the brief)
because a counter is cheap, needs no Swift changes, and keeps `ok` meaningful if
and when the device path is repaired — the honest answer changes automatically
rather than needing a doc edit.

## Consequences

- The platform matrix in `Mob.Test` gets worse on paper and honest in practice:
  simulator `tap_xy` works for `Button` and text fields only; device `tap_xy`
  returns `{error, no_effect}` for every coordinate today. `Mob.Test.tap/2` (by
  tag) remains the way to drive Mob screens and is unaffected.
- **Sidecar mode caveat.** The counter only sees handlers Mob owns. Driving a
  non-Mob app, a genuinely successful tap still reports `{error, no_effect}`
  because there is nothing to observe. Documented on `Mob.Test.tap_xy/3`;
  callers there should verify with `ui_tree/1` or a screenshot. Closing this
  properly needs Phase 3 event interception (see `CLAUDE.md`), where the BEAM
  sees the touch stream itself. The counter is also process-wide, not per-tap:
  scroll notifications (`scroll_began`/`scroll_ended`/`scroll_settled`) bump it
  too, so any unrelated Mob event landing inside the settle window reads as the
  tap's effect — the check assumes a serial harness with one interaction in
  flight at a time.
- `swipe_xy/4` and `long_press_xy/3` share the injection path and still report on
  acceptance. Flagged in the matrix as unverified; converting them is the same
  mechanical change and is deliberately left out of this diff.
- 300ms is a guess tuned to SwiftUI's tap-gesture recognition delay. A slow
  handler that only sends to the BEAM after heavy work would report `no_effect`.
  Raise the constant if that shows up; don't remove the check.
