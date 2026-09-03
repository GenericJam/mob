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

## Addendum: `throttle: 0` could not be expressed either

Review of this change surfaced a second, independent reason config did not work
— one that would have survived the fix above and made it look ineffective.

Both `mob_throttle_check` and the Zig `throttleCheck` used **zero as the "unset"
sentinel**:

```c
int throttle_ms = h->throttle_ms ? h->throttle_ms : default_throttle_ms;
```

`Mob.Event.Throttle` documents `on_scroll: {pid, tag, throttle: 0}` as the raw
escape hatch, with a doctest, and `renderer.ex` repeats it. So the one value an
app reaches for to *disable* throttling was the one value that collided with
"never configured" and silently produced the default instead. The iOS struct
comment even said `// 0 = no throttle (raw firing)` — the code contradicted its
own documented intent.

Fixed with an explicit `throttle_configured` flag on both platforms, set by
`mob_set_throttle_config` and cleared by `clear_taps` alongside the rest of the
per-handle throttle state. An unconfigured slot takes the built-in default; a
configured one takes what the app asked for, including 0.

Verified on the Pixel 8 emulator, three scroll nodes and one gesture each:

```
A default 33ms                20 events
B configured 500ms             4 events
C raw (throttle: 0, delta: 0) 41 events
```

C is the case that could not previously exist — before this it was
indistinguishable from A.

**Scope, stated plainly.** This makes `throttle` and `delta` work.
`debounce_ms`, `leading` and `trailing` are carried on the wire, stored by
`mob_set_throttle_config`, and **read by nothing** on either platform. The
original framing of MOB-134 ("throttle/debounce config never reaches native")
is therefore only half fixed: debounce still does not work, because nothing
implements it. `leading`/`trailing` defaults were at least made consistent —
`clear_taps` sets them to 1 while a freshly grown slot was memset to 0, so a
slot's default depended on whether it arrived by growth or reuse.
