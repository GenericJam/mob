# The adaptive theme watcher goes by what was passed to `Mob.Theme.set/1`
- Date: 2026-10-13
- Status: accepted

## Context

`Mob.Theme.AdaptiveWatcher` must re-resolve the theme on an OS light/dark
flip, but only when the app chose the adaptive theme; re-setting anything
else would overwrite an explicit choice. It decided by checking
`Mob.Theme.current() == adaptive.theme()`. The event arrives after the OS
flipped, so `theme/0` already returns the new scheme's theme and never equals
the still-old active one: the check was false exactly when a re-resolve was
needed (MOB-479, seen with `Mob.Theme.Adaptive` and Bezalel's
`MobBezalel.System` on the iOS simulator).

## Decision

`Mob.Theme.set/1` records what it was given in `Application` env
(`:mob, :theme_source`, read through the internal `Mob.Theme.source/0`):

- a module → the module;
- `{module, overrides}` → the tuple;
- a `%Mob.Theme{}` struct or a keyword list → `nil`.

On `:color_scheme_changed` the watcher re-sets the source when it is the
registered adaptive module, or `{adaptive, overrides}` (so the overrides
survive the flip). Anything else is a fixed theme and is left alone, including
a struct that happens to equal what the adaptive module returns: passing a
struct is an explicit fixed choice.

## Consequences

- Any later `set/1` with something other than the adaptive module stops the
  following, which is the "don't clobber the user's choice" rule the watcher
  always meant to keep.
- Framework code that layers onto the active theme must keep the source.
  `Mob.Plugins.apply_default_font/0` runs at boot after `use Mob.App,
  theme:`; it turns a module source into `{module, fonts: ...}` instead of
  setting a struct, which would have stopped `Mob.Theme.Adaptive` following
  the OS in any app with a font-suggesting plugin. The fonts map is the one
  active at boot, so a custom adaptive module whose light and dark themes
  carry different fonts keeps the boot scheme's fonts.
- `register_adaptive/1` after the theme was set needs no re-set: the watcher
  compares at event time.
- `set/1` writes two env keys non-atomically. Two processes calling `set/1`
  at once could pair one call's theme with the other's source; concurrent
  `set/1` was already unordered (the native palette push races the same way).
- The watcher does not re-render mounted screens; they pick the new theme up
  on their next render.
