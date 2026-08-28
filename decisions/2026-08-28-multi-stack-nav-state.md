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

### An unmatched root gets a private orphan stack

`Mob.Nav.from_layout/2` makes active the stack whose `:root` is the mounted
module. When no stack declares it — `start_root/1` on a splash, login, or
deep-link target — the screen goes under a reserved `:__mob_root__` stack that
is absent from both `order` and `roots`.

Two alternatives were rejected. Leaving `active` as `nil` means there is nowhere
to park the running screen, so the first `switch_tab` discards its socket and
history outright. Falling back to the *first declared stack* preserves the state
but is worse in a way that is easy to miss: switching to the stack you are
already on is a `:noop`, so the squatting screen makes that stack's real root
permanently unreachable from the tab bar. An app declaring
`tab_bar([stack(:home, root: HomeScreen), ...])` but booting on `SplashScreen`
would never be able to reach `HomeScreen` again.

The orphan stack preserves the screen's state *and* leaves every declared root
reachable. It is not itself a switch target, which is correct: no tab
corresponds to it.

### Back at a secondary stack's root returns to the first stack

`Mob.Nav.back_target/1` returns `{:switch, first}` when the active stack is a
declared stack other than the first, and `:exit` otherwise.

Once `history/1` means *the active stack's* history, the old back handler —
"empty history, therefore exit the app" — would kill the app from the root of
any tab, discarding every parked stack. That is both the Android convention
violated (back returns to the first tab, and only then exits) and a direct
contradiction of the feature: the parked state exists precisely so it survives.

### An unrecognised `navigation/1` return is ignored, not a raise

`from_layout/2` has a catch-all returning the empty state. `navigation/1` is
app-supplied and unvalidated, and `Nav.Registry.register_nav/1` has always
tolerated an unrecognised shape with `defp register_nav(_), do: :ok`. Since
`from_layout/2` runs inside `Mob.Screen.init/1`, raising would turn a
declaration the framework previously ignored (`def navigation(_), do: []` is the
obvious spelling) into a failure to boot, with no supervision to absorb it until
MOB-112 lands.

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
- **Known gaps, filed against the epic rather than fixed here.** `reset_to/2`
  still clears the active stack's history without re-deriving which stack the
  destination belongs to, so resetting to another stack's root leaves two live
  instances of that screen in two stacks. Parked screens receive neither
  `terminate/2` nor `Mob.ScreenState` sync, so a `persist: true` screen on an
  inactive tab loses its assigns on exit. Re-selecting the active tab is a
  no-op rather than popping that stack to its root, which is what both
  platforms do. All three want the per-screen processes of MOB-112 to fix
  cleanly.
- `Mob.Test.inspect/1`'s `:nav_history` key and `Mob.Screen.get_nav_history/1`
  both keep their shape, now reporting the *active* stack's history.
