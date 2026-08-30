# view_tree colour cannot be read from the layer tree on iOS 26

- Date: 2026-08-09
- Status: accepted

## Context

`Mob.Test.view_tree/1` returned no colour, so a styling regression was invisible
to the one introspection API meant to show what the device actually drew. The
motivating bug: under a glass theme the iOS renderer discarded every Box
background colour, and confirming it required pixel-diffing screenshots by hand.

The first fix read `UIView.backgroundColor` / `UILabel.textColor`. On a real
Mob screen that produced colour for **2 of 443 nodes**. A second attempt walked
the layer tree as well — `CALayer.backgroundColor`, `CAShapeLayer.fillColor`,
`CATextLayer.foregroundColor` — reaching **4 of 443**.

`:mob_nif.ui_paint_debug/0` (added here) censuses where paint actually lives.
Measured on an iPhone 17 simulator, iOS 26, against a 61-component app:

    total_views=442  groups=18
    204x SwiftUI._UIInheritedView / CALayer            all paint props 0
     72x UIPlatformGlassInteractionView / CALayer      all paint props 0
     64x SwiftUI._UIInheritedView / SwiftUI.SDFLayer   all paint props 0
     37x _UIInheritedView / SDFLayer + SDFPortalLayer  all paint props 0
     14x _UIInheritedView / CGDrawingLayer             all 0, contents=14

Every group reports zero for view background, layer background, shape fill,
gradient, text-layer foreground and UIKit text colour.

## Decision

Layer-based colour extraction is a dead end for SwiftUI-rendered content, not a
bug to keep fixing. On iOS 26 SwiftUI paints through `SDFLayer` (a
signed-distance-field renderer whose colour is not exposed as a layer property)
or rasterises into `contents`. Mob's renderer uses `.background(Color, in:)` and
`.foregroundColor` for every Box and Text, so essentially all app content is
invisible to this approach.

The colour fields stay, because they are correct where they resolve (UIKit
chrome, the root background, and any future Android implementation), and the
`:class` field added alongside them tells the caller which renderer drew a node
and therefore why a colour is `nil`. But they must not be presented as a way to
verify Mob styling.

**Colour verification belongs on screenshot sampling.** `Mob.Test` already has
`screenshot/2` and `element_frames/1`; sampling a node's frame from a capture
answers "what colour was actually drawn" without depending on private renderer
internals, works identically on both platforms, and survives Apple changing them.

## Consequences

- `view_tree` colour is best-effort and nearly always `nil` for SwiftUI content.
  Documented as such in `Mob.Test`.
- A styling regression is still NOT detectable from the tree. The follow-up —
  a sampling helper (e.g. `sample_color(node, id)`) — is what closes that gap.
- `ui_paint_debug/0` is kept deliberately. It answered this question in one RPC
  and will answer it again when Apple changes the internals; re-deriving it by
  reading SwiftUI class names across device rebuilds is the slow way.
