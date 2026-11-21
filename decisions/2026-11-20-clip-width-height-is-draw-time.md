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
- **The cut is one line per named axis.** `clip_width` cuts at the line
  `f × width` in from the leading edge, `clip_height` at `f × height` down
  from the top. Everything on the kept side stays, including what the node
  draws past its own leading or top bound, and an axis without a prop is not
  cut: with `clip_width` alone, anything drawn above or below the bounds (a
  glyph's overhang, an offset child) stays visible. A band starting at the
  leading bound was tried first and rejected: iOS strokes borders centred on
  the bounds, so it halved the leading border of a clipped bordered box while
  the top and bottom borders kept their full width.
- **`clip_width` keeps the leading part**: the left in a left-to-right layout,
  the right in a right-to-left one, so a half star fills from the side the
  rating is read from. `clip_height` keeps the top.
- iOS (`ios/MobRootView.swift`, `MobDrawClip` / `MobLeadingFractionShape`):
  one `.clipShape` attached in `MobNodeView.body`, the path every node type
  passes through, after `MobLayoutWeight` (which repaints a weighted node's
  background and border) and before `.offset` (so the clip travels with the
  node). The shape's path is built for left-to-right: SwiftUI mirrors a clip
  shape when `layoutDirection` is `.rightToLeft`, so the kept side lands on
  the leading edge. Resolving RTL inside the shape as well flips it back to
  the trailing side; an `ImageRenderer` probe on macOS showed exactly that
  before the shape was simplified. Nodes without a clip get no `.clipShape`
  at all.
- A `:sheet`'s own view in `MobNodeView` is a zero-size anchor, so the clip
  goes on the presented content in `MobSheetView` instead. Toggling a clip on
  the anchor would also have remounted `MobSheetView` and re-presented the
  sheet. An `:anchored` panel is drawn above the screen (iOS) or in a `Popup`
  (Android), outside the node, so only the anchor is clipped.
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
