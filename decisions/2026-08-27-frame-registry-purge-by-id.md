# iOS element_frames registry: purge-by-id, not wipe-and-repopulate

- Date: 2026-08-27
- Status: accepted; extended by `2026-08-27-frame-registry-liveness.md`
  (the decision below stands, but its "nothing to race" claim is overstated —
  see that file for the teardown case it misses, and for the tree-present
  but not-laid-out elements purge-by-id can't see)

## Context

`Mob.Test.element_frames/1` (backed by `mob_register_frame`/`element_frames`
in `ios/mob_nif.m`) lets an agent read a tagged element's on-screen frame
without a screenshot. The registry was cleared unconditionally
(`mob_clear_frames()`) at the top of every `nif_set_root` call, on the
assumption that `MobFrameTracker`'s `.background(GeometryReader{...})` in
`MobRootView.swift` would reliably repopulate every surviving element on its
next layout pass.

That assumption was wrong in a specific, confirmed way: `MobFrameTracker`
registered via `.onChange(of: geo.frame(in: .global), initial: true)`, which
only re-fires when the frame's *value* changes. An element whose on-screen
position/size is unchanged between two renders — the common case for most of
a screen on most renders — never got a new `onChange` firing, so its entry
stayed wiped until something eventually moved it. `Mob.Test.element_frames`
would report a still-visible, unmoved element as missing.

## Decision

Replace the registry's clear step with a **purge by id**: `nif_set_root`
parses the incoming tree first, walks it to collect every `:id` present
(`mob_collect_frame_ids`), and removes only the registry entries whose id is
*not* in that set (`mob_purge_frames_except`). A surviving element's
existing entry is never touched — nothing to race, nothing that needs to
"repopulate." `MobFrameTracker`'s original `onChange(of: frame, initial:
true)` is untouched and still the only thing that writes an entry, exactly
as before this change; it just no longer needs to fire on every render, only
on a genuine first-appearance or a real frame change.

### Approaches tried and rejected

Three variations of "make every surviving element re-register on every
render" were tried and rejected, all for the same underlying reason,
confirmed by device testing with an instrumented native build
(`NSLog` in `mob_register_frame`/the clear step, watched live via `xcrun
simctl spawn <udid> log stream`) plus a two-element repro screen (one
element that never moves, one removed by a later tap):

1. **`onChange(of: MobViewModel.shared.rootVersion)`** (via
   `@ObservedObject`) — forces re-registration on every render. Fixed the
   "static element survives a no-op-frame rerender" case, but a removed
   element's entry *also* survived its own removal: an `@Published` change
   reaches every still-mounted subscriber, including a view mid-removal in
   the same transaction, before SwiftUI finishes pruning views absent from
   the new declared tree.
2. **Same mechanism via a custom `@Environment` key** instead of
   `@ObservedObject` — same failure. Environment propagation turned out to
   have the identical property: a view being removed still gets evaluated
   with the updated environment value one more time.
3. **Direct, unconditional registration inside the `GeometryReader` closure
   body** (no `onChange` at all) — correctly stopped the removed element
   from reappearing, but was unreliable for the *surviving* element: it
   worked for one kind of sibling change and not another, indicating the
   closure isn't dependably re-invoked on every render regardless of
   whether *this* element's own geometry needs recomputing.
4. **Combining #2 with `.id(generation)`** on the tracking subview, to try
   to force a fresh reconstruction every render — no different result than
   #2 alone.

All four shared the same root issue: they tried to make **registration**
race-proof against SwiftUI's removal timing. Purging by id sidesteps the
race entirely by making the **registry's list of what should exist**
authoritative, computed directly from the tree BEAM just sent — not
inferred from which views happen to fire a reactive callback.

## Consequences

- `MobRootView.swift` is unchanged. The fix is entirely in `ios/mob_nif.m`:
  `nif_set_root` now parses the tree before touching the registry (it used
  to clear first, parse second), and calls `mob_purge_frames_except` with
  the freshly-collected id set instead of `mob_clear_frames`.
- Verified device-side (iOS 17 Pro simulator) via a throwaway two-element
  screen and a scripted `Mob.Test`-equivalent RPC sequence: a static
  element survives an unrelated sibling's re-render, and a removed
  element's frame disappears on the same render that removes it. No
  automated regression test exists for this (no XCTest target in this
  repo — see `CLAUDE.md`'s native-change verification note); this is a
  documented, reproducible manual verification, not CI-enforced.
- If SwiftUI's removal-pass timing ever needs the *reverse* signal (e.g.
  "notify me when an element is about to be removed, before it happens"),
  this same purge-by-id computation (`mob_collect_frame_ids`) is the
  natural place to diff old-vs-new id sets and produce that.
