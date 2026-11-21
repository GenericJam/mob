# `clip_width` / `clip_height` clip at draw time and keep the leading edge
- Date: 2026-11-20
- Status: accepted

## Context

mishka_chelekom's `MishkaRating` draws a half star by stacking a filled glyph
over an empty one inside a box and giving the filled one `clip_width: 0.5`.
No mob renderer read `clip_width`, so the filled glyph drew whole and every
half star rendered as a full one (MOB-536). The same partial fill shows up in
any "fill to a fraction" widget: ratings, battery and level meters.

Two shapes were available. A layout prop (a width of half the glyph, with the
content left to overflow and be clipped) changes the node's measured size, so
the stacked glyphs no longer line up and the row around them moves. A draw
prop keeps the measured size and only cuts what is painted, which is how the
platforms already do it: Android's `RatingBar` fills stars with a
`ClipDrawable`, and the Cosmos iOS rating library shrinks the filled layer.

## Decision

- `clip_width` and `clip_height` are generic props on every node type. The
  value is the fraction (0–1) of the node's own laid-out width or height that
  stays visible. Absent or >= 1 is no clip, <= 0 draws nothing, both set keeps
  their intersection.
- **Draw time only.** The node measures and places at full size, so its parent
  and siblings lay out as if the prop were absent. It cuts everything the node
  draws — its background, border and children — and nothing outside it.
- **Only the named axis is cut.** With `clip_width` alone, anything the node
  draws above or below its bounds (a glyph's overhang, an offset child) stays
  visible; along a cut axis the band is measured from the node's own bounds.
- **`clip_width` keeps the leading part**: the left in a left-to-right layout,
  the right in a right-to-left one, so a half star fills from the side the
  rating is read from. `clip_height` keeps the top.
- iOS (`ios/MobRootView.swift`, `MobDrawClip` / `MobLeadingFractionShape`):
  one `.clipShape` attached in `MobNodeView.body`, the path every node type
  passes through, after `MobLayoutWeight` (which repaints a weighted node's
  background and border) and before `.offset` (so the clip travels with the
  node). The shape's path keeps the *left* part of the rect: SwiftUI mirrors
  a clip shape when `layoutDirection` is `.rightToLeft`, so the left part of
  the path lands on the leading side. Resolving RTL inside the shape as well
  flips it back to the trailing side; an `ImageRenderer` probe on macOS showed
  exactly that before the shape was simplified. Nodes without a clip get no
  `.clipShape` at all.
- Android (mob_new's `MobBridge.kt`, `mobFractionClip`): a `drawWithContent`
  with a `clipRect` at the head of `nodeModifier`, reading the DrawScope's
  `layoutDirection`.

## Consequences

- An app on a mob with these props but a host generated before the mob_new
  release that adds them draws the clip on iOS only.
- Turning a clip on or off swaps the node between a clipped and an unclipped
  branch, which SwiftUI treats as a new view: native state below it (a text
  field's draft, a nested scroll offset) resets at that moment. Changing the
  fraction while it stays below 1 keeps the view. The same holds for the other
  conditionally attached node modifiers.
- Hit testing is not part of the contract: the props say what is drawn, not
  what can be tapped.
