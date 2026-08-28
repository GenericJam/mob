# Multi-stack navigation state: where the active screen lives

- Date: 2026-08-28
- Status: accepted
- Implements: MOB-109, first step of MOB-108
- Builds on: `2026-08-27-screen-process-architecture.md`

## Context

`Mob.Screen` carried a single `nav_history` list. `Mob.App.tab_bar/1` and
`drawer/1` have been public API in `Mob.App`'s moduledoc for far longer, and
`Mob.Socket.switch_tab/2` has been callable the whole time — but
`apply_nav_action/3` handled `{:switch_tab, _}` by clearing the action with the
comment "Tab switching is handled renderer-side". Nothing handled it anywhere.
One history cannot hold two stacks, so the runtime could not back the API it
shipped.

MOB-108 moves to per-screen processes eventually. Multi-stack state is required
at every level of that design and is independently valuable, so it lands first.

## Decision

### The active stack's current screen stays out of the struct

`%Mob.Nav{}` holds the active stack's `history` plus the fully parked state of
every *inactive* stack. The active screen itself remains where it always was, in
`Mob.Screen`'s `{module, socket}` slots.

The alternative — moving the current screen into `stacks[active].current` — is
tidier on paper and was rejected. Every `handle_call`/`handle_info` clause in
`Mob.Screen` destructures `{module, socket, _, _}`; routing the hot path through
a map lookup and write would touch all of them, for a state shape that MOB-112
replaces with real processes anyway. Only `switch/3` moves state in or out of
`parked`, so an ordinary message to the active screen reads and writes exactly
the two variables it did before. The change is confined to the navigation code.

### Stacks materialize on first visit

A declared stack has no socket and has never mounted until it is first switched
to. This matches `UITabBarController`, which does not instantiate a tab's view
controller until selected. After the first visit its state is retained for the
app's lifetime.

The cost is that "preserves state" is only true from the second visit onward,
which is what the platforms do and what users expect.

### A tab switch renders with `:none`, not `:push`

`Mob.Renderer.render/4` passes the transition to `nif.set_transition/1`, and
native understands `:push`, `:pop`, `:reset`, `:none`. A switch is a swap, not a
move along a stack — rendering it as `:push` would slide the incoming tab in
from the right on iOS. Using `:none` also keeps to atoms native already accepts,
so this lands with no `.m`, `.zig`, or template change, as the epic requires.

### An unmatched root falls back to the first declared stack

`Mob.Nav.from_layout/2` makes active the stack whose `:root` is the mounted
module. When no stack declares it — an app that calls `start_root/1` with a
module that is not any stack's root — the first declared stack is used rather
than leaving `active` as `nil`.

`nil` was the more honest answer and is worse in practice: with no active stack
there is nowhere to park the running screen, so the first `switch_tab` would
discard its socket and history outright. The fallback misattributes a label; the
alternative loses user state. The screen is preserved either way, and the
misattribution only occurs in a configuration that is already unusual.

### Unknown stacks are a no-op, not a raise

`Mob.Socket.switch_tab/2` takes any atom and offers no compile-time check.
A typo leaves navigation untouched rather than crashing the screen — which,
until MOB-112 lands per-screen supervision, would take the whole app with it.

## Consequences

- `Nav.Registry` now records two things: the flat route table that backs
  `push_screen/2,3`, and a per-platform layout preserving the declaration tree.
  The route table alone could not distinguish sibling stacks from unrelated
  routes. A second ETS table holds the layouts; `layout/1` returns `nil` when
  the registry was never started, which is the case in tests that drive a
  screen directly.
- Parked sockets keep the `:safe_area` they had when parked. A device rotated
  while a tab was inactive restores a stale inset — the same behaviour `pop`
  already has, so this is consistent rather than new. Worth fixing for both
  paths at once, not for this one alone.
- Pop, `pop_to_root`, and `pop_to` operate on the active stack only. Nothing
  can pop across a stack boundary, which is what makes the histories genuinely
  independent.
- `Mob.Test.inspect/1`'s `:nav_history` key and `Mob.Screen.get_nav_history/1`
  both keep their shape, now reporting the *active* stack's history.
