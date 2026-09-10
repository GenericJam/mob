# Wrap is a measured native layout primitive

Date: 2026-09-10
Status: accepted
Ticket: MOB-175

## Context

Chip and pill collections need to reflow from their actual rendered widths.
Packing by character count fails for proportional fonts, localization, theme
type scaling, and narrow devices. A horizontal scroll rail avoids the packing
error but changes the interaction and can hide available choices.

Chelekom's chip root explicitly uses `fill_width: false`. Native boxes
historically filled the row even when that explicit value was present, so a
flow container alone would still place every chip on its own line.

## Decision

Add `:wrap` as a cross-platform wire primitive. It greedily preserves source
order and starts a new run when the next child's measured width would exceed
the proposed width. `spacing` separates items and `run_spacing` separates runs;
both participate in Mob theme spacing-token resolution. A child with
`fill_width: true` occupies a whole run, while `weight` remains defined only in
rows and columns.

SwiftUI uses a custom `Layout`, available at Mob's iOS 17 deployment target.
Compose uses `FlowRow`. Both renderers also distinguish an absent box
`fill_width` from explicit `false`: absence preserves the historical full-width
box default, while explicit false hugs the content.

## Consequences

- Chip and pill collections respond to their real native measurement rather
  than an estimated character budget.
- Existing boxes that omit `fill_width` retain their layout.
- An intrinsically sized child wider than the container is proposed the
  available width; an explicit fixed width remains an overflow escape hatch.
- SwiftUI mirrors physical placement in right-to-left environments, matching
  Compose's layout-direction-aware `FlowRow` while preserving source order.
- OS Dynamic Type is still outside this primitive's scope because Mob currently
  sends fixed authored font sizes to SwiftUI. Authored `text_size` and theme
  scale changes do trigger fresh native measurement and reflow.
