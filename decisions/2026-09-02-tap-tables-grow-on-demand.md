# The tap-handle tables grow on demand

- Date: 2026-09-02
- Status: accepted
- Implements: MOB-133 (the half that was left open)
- Builds on: `2026-09-02-register-tap-owns-the-table-high-water-mark.md`

## Context

The tap registry was a fixed `TapHandle tap_tables[2][256]`, and the handle
encoding packed 8 slot bits into a positive `int32` alongside 23 generation
bits. Anything past slot 255 got the `-1` "no handler" sentinel from
`register_tap`.

That is not a graceful degradation. The element still renders, still looks
tappable, and simply **does nothing** — no error, no crash, nothing in the UI to
suggest the tap was ever wired up. On the benchmark screen it was **359 of 615**
interactive elements: a 200-row list where more than half the buttons, fields
and toggles were inert.

The earlier half of MOB-133 fixed the *reporting* — the exhaustion path used to
`NSLog` once per overflowing element, 359 synchronous system-log writes per
frame, which was 13 ms of a 27 ms frame. That made the failure cheap to observe.
It did not make the elements work.

## Decision

Two changes, and they have to happen together.

**The handle encoding gives slots 12 bits instead of 8.** A handle is a positive
`int32`, so there are 31 bits to divide. Slots go from 256 to **4096** and the
generation drops from 23 bits to 19. That trade is what the split costs, and it is worth
stating precisely rather than waving at.

At 60 fps, 2^19 frames is about **2.4 hours** of continuous rendering before the
generation wraps — down from 38.8 hours with 23 bits, a 16x reduction. After a
full cycle a stale handle is *numerically identical* to a fresh one, so
`slotForActive`'s exact-generation match cannot tell them apart. `generationAge`
being modular makes the arithmetic correct across the wrap; it does **not**
prevent that alias, and an earlier draft of this record implied it did.

What keeps it theoretical is that reaching it needs the UI layer to hold a
handle unused for a full cycle — which `mob_unregister_frame` and the frame
generation machinery already work against — and a handle is only meaningful for
the frame it was minted in, or a run of frames where its PID and tag are
unchanged. Small, real, and accepted; not covered.

**The tables are allocated to fit rather than declared at the ceiling.** A fixed
4096-entry pair would be roughly 700 KB resident in every app, and almost every
app registers a few dozen handles. They start at 256 — the old size, so no app
pays more than it did — and double on demand up to the encoding's ceiling.

Growth is safe because of an invariant that already held: **every reader
resolves under `tap_mutex`**. `mob_resolve_active_tap_locked` and its Zig twin
are only ever called with the lock held, and the pointers they return are used
before it is released. Growth takes the same lock, so nothing can be holding a
pointer into a table while it moves. Only the table being *built* is grown
mid-frame; the active one is untouched until the swap in `set_root` repoints
`tap_handles` at it.

One ordering detail matters and is easy to get wrong: `register_tap` must grow
**before** it caches `TapHandle *build = tap_tables[1 - tap_active]`. Caching
first and growing second is a use-after-realloc.

## Verification

Both platforms, on real hardware, end to end — not just "registers without
complaint" but "responds when tapped":

- **Android (Moto G Power)**: 200 rows registers 610 handles and 500 rows
  registers 1510, with **zero** exhaustion reports where there were 359 per
  frame. Scrolled to row **#188** — slot ≈ 564, well past the old cap — and
  tapped its button twice; the screen's tap counter went 0 → 1 → 2.
- **iOS (simulator)**: 615 and 1515 handles, zero exhaustion. Scrolled to row
  **#92** — slot ≈ 283 — and tapped twice; the header counter read `t/n/g=2/0/0`.

Worth stating why the tap, not just the count: `Mob.RenderStats`'s `taps` counts
handle-valued props, and `-1` is an integer. It read 615 *before* this fix too.
The exhaustion count is the honest signal for registration, and only an actual
tap proves the handle resolves.

The codec has eight unit tests, three of them new: the bit split sums to 31 and
every slot round-trips under the lowest and highest legal generations with the
handle staying positive (a negative handle would collide with the `-1`
sentinel); a slot past the limit is refused rather than wrapping onto slot 0;
and an old 8-bit-split handle does not decode to a live (generation, slot) pair.

## Consequences

- The ceiling is now 4096 rather than 256, but it is still a ceiling. Past it the
  sentinel path and the once-per-frame report still apply — a screen with more
  than 4096 interactive elements is telling you something else is wrong.
- Two `realloc`-backed tables mean allocation failure is now possible where it
  was not. It is treated exactly like exhaustion: the sentinel, and the report.
- The real fix for a list this dense is to compose fewer of it — see MOB-128's
  opt-in lazy scroll, which registers only what is on screen. This change means
  the app degrades honestly rather than silently while that is adopted.
