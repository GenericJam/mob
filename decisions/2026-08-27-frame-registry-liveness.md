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
in the BEAM tree*. Those diverge in three ways.

**1. In the tree, but not laid out.** `.lazyList` renders into a `LazyVStack`,
`MobTabView` keeps every tab's subtree in the tree while displaying one, and a
dismissed sheet's content stays mounted by design. In all three the `:id`
remains in the tree, so the purge never drops it, and `onChange` never fires
again — so the element's last on-screen frame is reported forever. Scroll a
500-row list to row 200 and `element_frames` still places `row_3` where it sat
200 rows ago; `tap_id(node, "row_3")` then taps whatever occupies those
coordinates now. Under the pre-MOB-102 wipe that was `{:error, :not_found}`, so
MOB-102 turned a safe failure into a silently wrong action.

**2. The teardown race is narrowed, not closed.** `mob_adopt_frame_ids` runs
synchronously on the NIF thread inside `nif_set_root`, while
`MobViewModel.setRoot` is `DispatchQueue.main.async` — the main thread hasn't
applied the new root yet. Outgoing screens then animate out under
`.transition(navTransition(...))`, which is `.move` for push/pop, so their
global frames change continuously and their `GeometryReader`s keep firing
`onChange` the whole way out, re-registering at mid-animation coordinates
*after* the purge already ran. Tree membership cannot reject this when both
screens tag an element with the same `:id` — that id genuinely is in the new
tree.

**3. Trackers are not bound to an `:id`.** Every `ForEach` in `MobRootView.swift`
keys children by index (`id: \.offset`) while the registry is keyed by `:id`.
Delete an item from a list and every later id shifts down one position, under
a tracker that keeps its view identity. If the rows are the same height the
tracker's own frame value is unchanged, so nothing fires — and the id it just
inherited keeps the previous occupant's entry, or loses it entirely to the
departing tracker's teardown.

## Decision

Keep purge-by-id and add the three things it can't express on its own.

**Liveness signal: compare-and-delete on `.onDisappear`.** `mob_register_frame`
returns a monotonic write seq, which `MobFrameTracker` keeps and hands back on
`.onDisappear` via `mob_unregister_frame(id, seq)`. The entry is removed only
if that write is still the current one, so a tracker can only ever delete an
entry it still owns. A lazy row scrolling off or a tab deactivating drops its
own entry.

This is deliberately on the *unregistration* side. All four mechanisms MOB-102
tried and rejected were attempts to make *registration* race-proof against
removal timing; `.onDisappear` is the platform telling us an element stopped
being laid out, which is precisely the fact the registry was missing.

**Generation gating for navigation.** A non-`"none"` transition is what makes
`MobViewModel` bump `navVersion`, and `MobRootView` keys the whole tree on
`.id(currentNavVersion)` — so every view identity is destroyed and rebuilt.
`nif_set_root` bumps a frame generation in lockstep; a tracker captures the
current generation when it appears and stamps every write with it, and writes
carrying a superseded generation are refused. That makes "the outgoing screen
may not write" true even for an `:id` both screens share, which the seq
compare-and-delete alone was silently assuming. Because the refused write
returns seq 0 and `mob_unregister_frame` no-ops on 0, the outgoing tracker's
teardown also can't delete the incoming entry.

The generation is read through a plain C call, not `@Environment` or an
`@ObservedObject`. It is a rejection gate, not a repopulation trigger — the
distinction that separates it from MOB-102's rejected attempts 1, 2 and 4.

**Write gating on tree membership.** `nif_set_root` retains the live id set and
`mob_register_frame` ignores writes for ids not in it. Cheaper than the
generation check and catches the non-shared-id case directly.

**Registration that doesn't depend on `onChange` alone.** The tracker also
registers on `.onAppear`, and re-registers on `.onChange(of: id)`. The first
makes every disappear/reappear cycle self-healing, which matters because
`initial:` is not guaranteed to re-run when SwiftUI preserved the view identity
across the disappearance (a `TabView` tab demonstrably preserves `@State`
across switches). The second handles divergence 3: whichever order the
departing tracker's teardown and the inheriting tracker's re-registration land
in, the surviving element ends up correctly registered at its new position.

Seqs live in a side table (`g_element_frame_seqs`) rather than as a fifth array
element, so `nif_element_frames` keeps JSON-encoding the registry directly and
the `{"id":[x,y,w,h]}` wire shape is unchanged. Per-tracker bookkeeping lives in
a reference box held by `@State`, not `@State` scalars: the writes happen inside
a layout-driven callback once per display frame per element during a transition,
which is the classic "modifying state during view update" shape, and the values
must stay readable during the same transaction that tears the view down.

### Known gap

A pure **reorder** of same-sized siblings still reports stale positions. List
`[a, b, c]` re-rendered as `[c, a, b]`: all three ids are still in the tree so
nothing is purged, no view is destroyed so no `.onDisappear` fires, and each
tracker's own frame value is unchanged, so `onChange(of: frame)` fires nowhere.
`onChange(of: id)` catches this only because the id under each index *does*
change — which it does here, so the reorder case is in fact covered by the same
mechanism as divergence 3. What is *not* covered is a reorder that leaves every
index holding the id it already had, which by definition isn't a reorder. Keying
the `ForEach`s on `nativeViewId` instead of index would make this structural
rather than incidental, and is the better long-term fix; it changes SwiftUI
identity semantics across seven call sites (affecting `@State` preservation and
animations in every list), so it wants its own change and its own device pass.

## Consequences

- `mob_register_frame`'s signature changed (`void` → `uint64_t`, plus a
  generation parameter), so `MobDemo-Bridging-Header.h` and its one Swift
  caller move together. `mob_nif.m` now imports that header so the compiler
  diagnoses future drift — C has no name mangling, so before this a changed
  signature linked fine and Swift read whatever was in the return register.
  No generated-app template declares it (`mob_new`'s `build.zig.eex` passes
  mob's header by path), so `mob_new` needs no companion change.
- `nif_element_frames` now snapshots under the lock and serializes outside it.
  The main thread takes that lock on every frame write, and the docs tell
  callers to poll this NIF until a frame settles.
- **Host checks.** `ios/mob_nif.m` compiles clean (`clang -fsyntax-only
  -fobjc-arc` against the iOS 26.5 simulator SDK, with `MobApp-Swift.h` stubbed
  since it's generated by swiftc during the real build). `test/native/` holds a
  runnable harness (`make -C test/native run`) asserting twenty registry
  behaviours, including both MOB-102 non-regression cases and the shared-`:id`
  nav case — but it reproduces the registry functions rather than linking the
  shipped ones, so it checks the algorithm, not the binary.
- **Device-verified**, via a generated probe app (300-row `:list`, plus two
  screens deliberately tagging a button with the same `:id`) read over dist
  with `Mob.Test.element_frames/1`. On the iPhone 17 Pro simulator (iOS 26.4)
  and a physical iPhone (iOS 26.5.2):

  - *Divergence 1 — the headline.* Only the visible window is ever registered
    (12 of 300 rows on the simulator, 10 on the phone), so `LazyVStack` does
    destroy far-offscreen rows and `.onDisappear` does fire for them. After
    scrolling well past it, `row_3` is absent on **both** targets — the exact
    case that under MOB-102 alone reported a stale frame and produced a wrong
    tap. Rows scrolled back into range re-register, so the cycle is
    self-healing.
  - *MOB-102 non-regression.* `probe_title` and `shared_btn` — static and
    unmoved — survived all of that without re-registering.
  - *Divergence 2 — shared `:id` across a nav push.* The incoming screen's
    frame is what's reported (simulator y=512 vs the outgoing screen's y=112;
    phone y=470.5 vs 70.5), stable across repeated reads seconds after the
    animation, and restored exactly on pop. Neither deleted nor left at
    mid-animation coordinates.
  - *Backgrounding.* A background/foreground cycle leaves the registry intact.
  - *`MobTabView`.* This is the case the lazy-list result does **not** settle:
    a tab switching away keeps its subtree in the tree, and `TabView` preserves
    view identity across switches, so `.onAppear` re-firing on re-selection was
    an open question. Verified on the simulator with a real `tab_bar` render
    node: with tab A active only `tab_a_marker` is registered; switching to B
    drops it and registers `tab_b_marker`; switching back restores
    `tab_a_marker` — repeatably, in both directions. So `.onAppear` does
    re-fire on re-selection and a tab round trip is not permanently
    unreportable.

    Note the reachable path is the `tab_bar` **render node** (`props.tabs` +
    `props.active`), not `Mob.App.tab_bar/1` navigation. Also worth recording:
    `Mob.Renderer` has no `on_tab_select` handler, so that prop reaches native
    as a raw `{pid, tag}` tuple and kills the screen process on serialize —
    tab selection has to be driven from Elixir through `active`. That's a
    separate bug, not this change's.
- Only the `MobTabView` case was left simulator-only; the physical iPhone had
  rebound dist to its USB link-local address (`169.254.1.100`), which dist
  can't route to, and clearing that needs the cable physically unplugged. Every
  other scenario ran on both targets and agreed exactly, and the mechanism
  under test is SwiftUI behaviour rather than anything device-specific.
- `Mob.Test.element_frames/1`'s docstring now states the liveness rule, the
  settle caveat (a frame is a last-known position, not a synchronous read), and
  the reorder gap.
