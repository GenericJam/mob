# iOS element_frames: tree membership is not liveness

- Date: 2026-08-27
- Status: accepted
- Extends: `2026-08-27-frame-registry-purge-by-id.md` (that decision stands;
  this adds the second half it was missing)

## Context

MOB-102 replaced the unconditional `mob_clear_frames()` in `nif_set_root` with
a purge-by-id: collect every `:id` in the incoming tree, drop only the registry
entries whose id fell out of it. That correctly fixed the original bug (a
static, unmoved element's frame was wiped and never repopulated, because
`MobFrameTracker` only writes on `onChange(of: geo.frame)` and an unmoved
element never fires it).

But it swapped the predicate. `Mob.Test.element_frames/1` documents — and
`tap_id/2` depends on — *rendered on screen*. Purge-by-id implements *present
in the BEAM tree*. Those diverge in two ways, both found in review of PR #87:

**1. In the tree, but not laid out.** `.lazyList` renders into a `LazyVStack`,
so SwiftUI discards rows scrolled far out of range. `MobTabView` keeps every
tab's subtree in the tree simultaneously and displays only the active one. A
dismissed sheet's content stays mounted by design. In all three the `:id`
remains in the tree, so the purge never drops it, and `onChange` never fires
again — so the element's last on-screen frame is reported forever. Scroll a
500-row list to row 200 and `element_frames` still places `row_3` where it sat
200 rows ago; `tap_id(node, "row_3")` then taps whatever occupies those
coordinates now.

Under the pre-MOB-102 wipe, `row_3` was dropped and never re-registered while
offscreen, so `tap_id` returned `{:error, :not_found}`. MOB-102 turned a safe
failure into a silently wrong action — a regression for the exact tooling it
exists to serve.

**2. The teardown race is narrowed, not closed.** The purge-by-id doc claims
"nothing to race." That holds only for elements whose frame doesn't change
during teardown. `mob_adopt_frame_ids` runs synchronously on the NIF thread
inside `nif_set_root`, while `MobViewModel.setRoot` is `DispatchQueue.main.async`
— the main thread hasn't applied the new root yet. Outgoing screens then
animate out under `.transition(navTransition(...))`, and their `GeometryReader`
fires `onChange` the whole way down, re-registering at mid-animation
coordinates *after* the purge already ran.

## Decision

Keep purge-by-id and add the two things it can't express on its own.

**Liveness signal: compare-and-delete on `.onDisappear`.** `mob_register_frame`
now returns a monotonic write seq, which `MobFrameTracker` keeps in `@State`
and hands back on `.onDisappear` via `mob_unregister_frame(id, seq)`. The entry
is removed only if that write is still the current one. A lazy row scrolling
off or a tab deactivating drops its own entry; an outgoing screen whose `:id`
was legitimately re-claimed by an incoming screen cannot delete the new owner's
entry.

This is deliberately on the *unregistration* side. All four mechanisms MOB-102
tried and rejected were attempts to make *registration* race-proof against
removal timing; `.onDisappear` is the platform telling us an element stopped
being laid out, which is precisely the fact the registry was missing.

**Write gating: reject ids absent from the current tree.** `nif_set_root`
already computes the live id set; it's now retained, and `mob_register_frame`
ignores writes for ids not in it. That kills the mid-animation re-registration
in (2) for every id that isn't shared across the two screens.

The seqs live in a side table (`g_element_frame_seqs`) rather than as a fifth
array element, so `nif_element_frames` keeps JSON-encoding the registry
directly and the `{"id":[x,y,w,h]}` wire shape is unchanged.

### Residual, accepted

If an outgoing and an incoming screen share an `:id` (e.g. both tag a button
`"save"`), the dying screen's animation can still clobber the entry before its
`.onDisappear` removes it — which then leaves the id *absent* until the
surviving element next moves. That degrades to `{:error, :not_found}`, a safe
failure rather than a wrong tap, and only for ids reused across a nav
transition. Fully closing it needs per-element identity in the registry rather
than a bare `:id` key, which is a larger change than this bug warrants.

## Consequences

- `mob_register_frame`'s signature changed (`void` → `uint64_t`), so
  `MobDemo-Bridging-Header.h` and its one Swift caller move together. No
  generated-app template declares it, so `mob_new` needs no companion change.
- Verified by construction, not on device: `ios/mob_nif.m` compiles clean
  (`clang -fsyntax-only -fobjc-arc` against the iOS 26.5 simulator SDK), and
  the registry algorithm — ownership, gating, purge, and the MOB-102
  non-regression case — is covered by an executable harness asserting all
  twelve behaviours. **The SwiftUI half is unverified:** whether
  `.onDisappear` actually fires for a `LazyVStack` row leaving the render
  window and for a `TabView` tab switching away needs a device/simulator run.
  There is still no XCTest target in this repo, so that remains manual.
- `Mob.Test.element_frames/1`'s docstring now states both the liveness rule and
  the settle caveat (a frame is a last-known position, not a synchronous read).
