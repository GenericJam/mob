# Two-slot screen presentation

**Date:** 2026-09-04
**Issue:** MOB-129

## Context

`MobRootView` rendered the whole app as `MobNodeView(node: root).id(currentNavVersion)`, and `currentNavVersion` incremented on every non-`"none"` transition. `.id()` destroys and rebuilds a SwiftUI subtree, so every push, pop and reset threw away the entire native tree.

MOB-126 shipped native frame timing, which made the cost measurable for the first time. On a 1614-node / 113 KB screen, iPhone 17 Pro simulator, 150 samples per population, 0 dropped:

| transition | p50 |
|---|---|
| `none` | 65,723 us |
| `pop` | 226,244 us |
| `push` | 234,833 us |

The 169 ms gap scales linearly with node count: a 37-node screen showed a 3.8 ms gap, and 43.6x the nodes gave 44.9x the gap.

Two further measurements shaped the design.

**Building dominates, destroying does not.** Bouncing between the dense screen and a 37-node one isolates the halves: destroying a 1614-node tree costs about 26 ms, building one about 217 ms. So the issue's original framing, "stop discarding the tree", targets the cheap 11%.

**Identity preservation recovers the whole gap.** A one-line probe with a constant `.id()` took `push` from 234,833 us to 63,930 us, landing at the `none` floor, with a teardown delta of -1.4 ms. That is the theoretical maximum, and it says the entire 169 ms is the identity change and nothing else.

## Decision

Navigation no longer changes identity. Two slots sit at fixed structural positions in the root `ZStack` — that position **is** their identity, and no `.id()` is used — and a navigation ping-pongs between them. The slide is driven by an animated `slotOffset` rather than by `.transition()`.

**Why not `.transition()`.** It only fires on insert/remove, and insert/remove is precisely what costs 169 ms. Keeping the modifier means keeping the teardown. Driving the offset directly decouples the animation from identity, which is the whole trick.

**The outgoing slot is not cleared on push or pop.** Holding it gives depth-1 retention for free: popping back writes that screen's tree into the slot that still holds its previous tree, so SwiftUI diffs rather than rebuilds. One level is where nearly all back-navigation lands, and the cost is bounded at exactly two trees rather than growing with stack depth. A `reset` does clear it, because a reset replaces the stack and that screen is unreachable.

**`.equatable()` on the slot root is load-bearing, not an optimisation.** `nif_set_root` allocates a fresh `MobNode` graph on every render, so the active slot's reference always differs and its body always re-runs. The parked slot's reference does *not* change, because the BEAM only sends the active screen's tree. Without the equality check the parked slot would be re-evaluated on every render of the active one, and holding it would cost more than rebuilding it.

The comparison is reference identity (`===`), deliberately not content. Every interactive node's handle prop is `(generation << 12) | slot` and `clear_taps` bumps the generation on every render, so a content comparison is false for any subtree containing a tappable node — which is most of them. Reference identity is the only comparison that can ever be true, and because the graph is rebuilt wholesale, an unchanged reference at a subtree root means the entire subtree is untouched.

**Hit-testing is disabled explicitly on the parked slot** rather than being inferred from its offset. SwiftUI hit-tests over its own display list and does not necessarily honour zero opacity the way UIKit's `hitTest:` honours zero alpha, and `MobBoxSemantics` applies `.contentShape` liberally. A tappable parked screen would resolve handles from a superseded tap-table generation.

**Slide distance comes from the container's real geometry**, not `UIScreen`, so it is right under split view, Stage Manager and rotation. A parked slot's offset is re-applied on resize so it stays off-screen.

## Results

Same rig, 150 samples per population, 0 dropped:

| | before | after |
|---|---|---|
| `none` | 65,723 us | 66,594 us |
| `pop` | 226,244 us | **76,110 us** |
| `push` | 234,833 us | **75,642 us** |

**159 ms off a push, 150 ms off a pop**, with the animation intact. The remaining 9 ms over the no-animation probe is the cost of both trees being mounted during the slide, which is what `.transition()` did anyway.

Verified on the simulator: the animation plays in the correct direction for both push and pop, both screens are visible simultaneously mid-slide, screens settle at offset 0, and a synthetic touch on the active screen still triggers navigation.

## What this does not do

**A first visit to a screen still builds every node that does not yet exist.** No identity scheme avoids that.

What retention does buy, and it is more than the single-slot probe suggested, is that the *second* visit is cheap regardless of shape. Bouncing between the dense screen and a 37-node one:

| navigation | before | single-slot probe | two slots |
|---|---|---|---|
| pop, trivial out / dense in | 217,120 us | 190,314 us | **65,533 us** |
| push, dense out / trivial in | 25,766 us | 18,659 us | **8,370 us** |

The probe held one slot, so the two screens overwrote each other and every diff was cross-shape, which is why it only saved 12-28%. With two slots each screen returns to the slot holding its **own** previous tree, so after the first round trip both directions diff. That is exactly the shape of list-to-detail-and-back.

The cost is therefore paid once per screen per slot, not once per navigation. A linear drill-down A to B to C to D still builds each new screen; an alternating A-B-A-B pattern builds each once.

**It does not touch the 65.7 ms steady-state floor.** Changing one text node on a dense screen still costs that, because the platform walks the whole tree regardless. That is MOB-144.

**Retention is depth-1.** Popping two levels rebuilds. Deeper retention was not built because its cost grows with stack depth and its benefit was not measured; the ping-pong shape gives the first level for nothing.

## Hazards accepted, and the ones still open

A parked screen is now alive rather than destroyed, which invalidates assumptions elsewhere. Addressed here: hit-testing, and the frame-registry generation is untouched because the parked slot stops re-registering once it stops laying out.

**Still open and NOT fixed here**, because they need a parked screen to actually contain the widget in question:

* `MobSheetView` holds `@State isPresented = true` and `.sheet` presents on the window, so a screen parked with a sheet up may keep it over the new screen.
* `MobWKWebView` assigns the process-global `g_webview` from both `makeUIView` and `updateUIView`; two live screens with a web view will fight over it.
* `MobVideoPlayer` keeps playing, audio included, and `MobGpuView` runs unconditionally at 60 fps, so a parked screen with either keeps burning cycles.
* `MobLazyList`'s `on_end_reached` latch reasons explicitly that "only navigation changes the container's identity" — which this change makes false, so returning to a list already at its end will not re-fire pagination.

Each is small on its own and none is reachable without the corresponding widget on the parked screen. They are recorded on MOB-129 rather than fixed blind.
