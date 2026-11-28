# `Mob.Theme.set/1` repaints the screen on show in every window

- Date: 2026-11-27
- Status: accepted

## Context

Colour, spacing, radius and font tokens are resolved by `Mob.Renderer` when a
screen paints, so a screen kept its last paint's palette until something else
repainted it (MOB-575). `Mob.Theme.AdaptiveWatcher` only calls `set/1` on an
OS light/dark flip, and nothing repainted. Since MOB-567 the iOS root paints
the theme's `background` natively and follows the flip at once. A screen's
`:on_surface` text kept the old palette, so after a dark-to-light flip it was
light text on a light root until the user touched the screen.

## Decision

Every `set/1`, adaptive or not, calls `Mob.Router.theme_changed/0`. That
sends `{:mob_theme, :changed}` to `:mob_screen` and to every router in
`Mob.Scenes.list/0`. Each router forwards it to the screen it is showing,
`state.current`. `Mob.Screen.Server` handles the message internally, so the
user's `handle_info/2` never sees it, and repaints.

**Corrected 2026-11-27.** As merged in #258, each router forwarded the message
to all of its live screens (its history and parked tabs too), "as for a size
class change". The reason given was that a screen popped back to would
otherwise show the old palette. That was wrong. Mob.Sender drops the frames of
any screen that is not current, so those repaints never reached native. And a
screen that becomes current repaints unconditionally (an unskippable router
paint on every push, pop, reset and tab switch), in whatever theme is set then. A
size-class change has to reach every screen because it updates an assign the
screen holds; a theme change updates nothing the screen holds. So only the
current screen is told, which costs one render per window instead of one per
live screen.

- **The repaint is skippable** (`repaint_if_changed`). The frame fingerprint
  includes `Mob.Theme.current()`, so a screen that already painted under the
  new theme sends native nothing. That is the screen whose `mount/3` or
  `handle_info/2` called `set/1`, and every screen when `set/1` is called with
  the theme already active.
- **The fan-out runs in a spawned process.** `set/1` is called from screens,
  including from `mount/3`, which runs inside the router's synchronous start.
  A `GenServer.call` to `Mob.Scenes` from there must not be on the caller's
  path. `set/1` stays non-blocking, and the theme is already in the
  application env, so any paint that runs before the message arrives uses
  it.
- **Before a router exists** (`use Mob.App` sets the theme at boot), there is
  no `:mob_screen` and no `Mob.Scenes`, and nothing is sent.

## Consequences

- One render per window per theme change: the screen on show. A screen under
  the top of a stack or in a parked tab is repainted, in the new palette, when
  it becomes current.
- A screen no longer needs to repaint itself after calling `set/1`. Code that
  did so (an assign change after `set/1`) still works, and the second paint is
  skipped by the fingerprint.
