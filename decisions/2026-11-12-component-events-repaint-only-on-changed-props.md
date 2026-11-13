# Component events repaint only when the rendered props change

- Date: 2026-11-12
- Status: accepted
- Related: `2026-09-03-skip-the-repaint-when-the-tree-is-unchanged.md`

## Context

Every `Mob.Component` callback ended the same way: run `handle_event/3` or
`handle_info/2`, then send the screen `{:component_changed, id, module}`,
whatever the callback returned. The screen answered with `paint(state, :none)`,
which never skips: render, expand every component (a `render_props/1` call
each), fingerprint, and commit the whole tree through `set_root`.

The 2026-09-03 fingerprint skip did not reach this path. That record allowed
only a screen's forwarded messages to skip, and `{:component_changed, ...}` was
not one.

FMutate's instrument is a native view that sends an input event per key press,
key release and knob move. Its `handle_event/3` returns the socket unchanged
for key events. On a Moto G Power 2021, 6 presses gave 12 commits: 5-15 ms of
BEAM work and 10-20 ms of Compose recomposition on the UI thread each time.
That was the main source of jank left.

## Decision

Both sides now check.

**The component compares what the screen would fetch.** `Mob.ComponentServer`
keeps the props the screen last fetched with `render_props/1`. After a
callback it notifies only when assigns changed (`!==`, which returns at once
for the same term) **and** `render/1` of the new assigns differs (`!==`) from
those props. So a callback that returns the socket untouched, assigns the
same value again, or changes only an assign `render/1` does not read (FMutate's
`:bindings`) sends nothing. The comparison is against the last fetch, not the
last notice. A change made while a notice is still unanswered is fetched with
that notice, so comparing against the last fetch can only skip a notice the
screen did not need.

**The screen treats `{:component_changed, ...}` like its own messages.** It
repaints through `repaint_if_changed/1`, so a notice whose tree is already on
screen does not commit. This matters when several events queue up behind one
paint: the first paint fetches the latest props and the rest find the same
tree. The skip stays limited to message-driven paints. Navigation, activation,
hot reload and `:sync` still paint unconditionally, for the reasons the
2026-09-03 record gives, and those reasons hold here too: a component notice is
an ordinary message, and becoming active still goes through the router.

## Consequences

- `render/1` of a component is treated as a function of its assigns, as in
  LiveView. A component whose `render/1` reads something else (a clock, ETS)
  no longer sees it change on a callback that leaves assigns alone. It still
  sees it on the next screen paint, because `render_props/1` always renders
  again and is never served from a cache. The moduledoc says so.
- The parent screen is no longer re-rendered by a component event that leaves
  the component's props alone. A screen whose `render/1` reads state a
  component writes outside messages (ETS, an Agent) used to be refreshed by
  that event as a side effect; it now needs a message of its own, which goes
  through the screen's usual `repaint_if_changed/1`.
- Identical props are no longer re-sent to the native view. A native view that
  depended on a re-commit to drop local state the BEAM rejected (a "controlled"
  input whose handler returns the old value) no longer gets one. Screens have
  behaved this way since 2026-09-03. Compose and SwiftUI do not reset local
  state when props are equal anyway, so such a view was relying on a redundant
  commit. A component that needs the reset bumps an assign its `render/1`
  returns (a revision counter) when it rejects input; that is a props change,
  so it commits.
- A notice that does go out now costs one extra `render/1` in the component,
  for the comparison. A component render is a props map, far cheaper than the
  screen render and commit it can save.
- Assigns that change without a notice (the default `update/2` re-runs
  `mount/2` on every screen paint) are not a problem, because the screen
  fetches with `render_props/1` straight after `update/2`, and that fetch is
  what the comparison uses.
- `:rendered` is read with `Map.get/2` and written with `Map.put/3`, so a
  component started before this change keeps working after `mix mob.push`. With
  no fetch recorded, its first change notifies, as it did before.
- `:rendered` is render output, so it holds app data the same as the assigns
  do. `Mob.CrashReport.format_status/1` redacts it (keys kept, values
  `:redacted`; a non-map value becomes `:redacted`), so neither a component
  crash report nor `:sys.get_status/1` prints it (MOB-310). Any further
  component state derived from assigns needs the same treatment.
- Verified on devices, not only in host tests: on a Moto G Power 2021
  (Android 11) and an iPhone SE (3rd gen), a native view's no-op events, an
  unrendered-assign change and a rejected controlled input caused no screen
  render, and a rendered change caused exactly one.
- What this does not do: a screen still runs `render/1` and its expansion
  passes for every message it gets, even one that changed no assign. Only the
  commit is skipped. Skipping the render too would need every render input
  outside assigns covered (the theme, `__mob__` list renderers, safe area). That
  is a separate change.
