# Throttle config is applied to the table being built, not the active one

- Date: 2026-09-02
- Status: accepted
- Implements: MOB-134, part of MOB-124

## Context

Every `Mob.UI` throttle/debounce setting was silently discarded on iOS. The
call happened on every frame and always resolved to NULL.

`mob_set_throttle_config` is only ever reached from the `set_root` prop
deserialiser. That runs while the frame is still being built — `register_tap`
has written this frame's handlers into `tap_tables[1 - tap_active]`, and the
swap that makes that table active is ~50 lines further down `nif_set_root`.
So the handles in the JSON carry `tap_build_generation`, while
`mob_resolve_active_tap_locked` compares against
`tap_table_generations[tap_active]`, which is still the previous frame's
generation (`nif_clear_taps` zeroed the building slot's). The comparison
failed, the `if (tap)` body was skipped, and an app asking for
`throttle: 100, delta: 8` quietly ran at the built-in 33ms/1.0 default.

## Decision

Resolve against the building table first, falling back to the active one:

```c
TapHandle *tap = mob_resolve_build_tap_locked(handle);
if (!tap)
    tap = mob_resolve_active_tap_locked(handle);
```

The ordering makes this safe. `clear_taps` zeroes the building table's
throttle fields at the top of the frame; `register_tap` writes only
`pid`/`tag_env`/`tag`; the swap loop copies only `identity_start_generation`.
Config written during deserialisation therefore survives to the swap and is
live for the frame it describes. The active-table fallback keeps any future
caller outside a build working.

**Android needs no equivalent change, for a non-obvious reason.** Its swap
happens inside `nif_set_root` *before* Kotlin composes, so by the time Kotlin
could apply config the handles are already active — resolving against the
active table is correct there. Android's gap is that nothing calls the
function at all, which is the remaining half of MOB-134.

## Consequences

Verified on the iPhone 17 Pro simulator with two scroll nodes on one screen,
one default-throttled and one configured to `throttle: 500, delta: 1`, given
comparable one-second swipes:

```
default 33ms       33 events
configured 500ms    5 events
```

Before the change both ran at the default.

**The measurement only works if the handler does not re-render**, and that
caveat is the more important finding. `Mob.Screen.Server.forward/2` calls
`paint/2` unconditionally after every `handle_info`, whether or not assigns
changed. So a scroll handler that lives on the screen process re-renders on
every event; each render calls `clear_taps`, which zeroes `last_emit_ns`; and
`mob_throttle_check` treats `last_emit_ns == 0` as "no previous emission" and
emits unconditionally. The throttle is defeated by the very events it is
throttling.

The first attempt at this measurement showed 68 vs 69 events for the two
nodes and looked like the fix had failed. It had not — routing the same
handlers to a plain process instead of the screen gives the 33-vs-5 above.
That feedback loop is a MOB-124-shaped problem (per-frame handle churn, and
rendering driven by message arrival rather than by state change) and is
recorded on the issue rather than worked around here.
