# register_tap owns the tap table's high-water mark

- Date: 2026-09-02
- Status: accepted
- Implements: MOB-133
- Builds on: `2026-08-27-frame-registry-purge-by-id.md`

## Context

`nif_clear_taps` walked all `MAX_TAP_HANDLES` (256) slots every frame to free
the previous frame's `ErlNifEnv`s, even when the frame had used four. Bounding
the loop by a recorded high-water mark is the obvious fix, and it was made —
with `set_root` as the only writer of that mark.

That is wrong, and the reason is worth recording because the failure is silent.

## Decision

`nif_register_tap` maintains `tap_table_used`, not `nif_set_root`.

A frame can register taps and never reach `set_root`. `Mob.Renderer.render/4`
runs `clear_taps`, then `prepare` (one `register_tap` per handler prop), then
`:json.encode`, then `set_root` — and `Mob.Sender.commit/1` **rescues** anything
that raises in between, deliberately, so one screen's bad render cannot freeze
every other screen by taking down the sender.

So the rescued path leaked one `ErlNifEnv` per tap, per failed frame, forever, on
a path built to survive. A simulation of the verbatim logic showed 4900 live envs
after 50 failed 100-tap frames, and zero with the bound restored.

The rule: **the function that writes a slot is the function that must record it
was written.** Anything else assumes a later stage always runs.

`tap_exhausted_count` had the same shape — reset only inside `set_root`'s
reporting branch, so a frame that overflowed and then failed carried its count
into the next frame's report, which claims to describe "this frame". It resets in
`clear_taps` now, the one entry point every frame runs.

## The logging that started this

The exhaustion path called `LOGE` once per exhausted call. On a 200-row screen
that is 359 synchronous system-log writes per frame: **13 ms of a 27 ms frame,
47% of the total.** It read as "tap registration is the bottleneck" and nearly
redirected MOB-124. Counting and reporting once per frame took `register_tap`
from 13004 µs to 81 µs and halved the frame on its own.

A per-call log on a per-node path is not a diagnostic, it is the bottleneck.

## Still open

The cap itself. 615 handlers against 256 slots means 359 interactive elements
per frame get handle `-1` and silently do not respond. Raising or virtualising
the pool is unresolved; `MAX_TAP_HANDLES` is tied to the 8 slot bits in
`tap_handle_codec`, so raising it trades generation bits for slot bits.
