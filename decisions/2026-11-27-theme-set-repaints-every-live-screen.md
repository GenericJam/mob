# `Mob.Theme.set/1` repaints every live screen

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
`Mob.Scenes.list/0`. Each router forwards it to all of its live screens:
the current one, its history and the parked tabs, as for a size class change.
`Mob.Screen.Server` handles the message internally, so the user's
`handle_info/2` never sees it, and repaints.

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

- Screens under the top of a stack and in parked tabs render once per theme
  change. That is the same cost as a size-class change, and it means a screen
  popped back to is already in the new palette.
- A screen no longer needs to repaint itself after calling `set/1`. Code that
  did so (an assign change after `set/1`) still works, and the second paint is
  skipped by the fingerprint.
