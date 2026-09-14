# iOS: fixed_width / fixed_height beat fill_* on Column and Row

- Date: 2026-09-11
- Status: amended by MOB-233 on 2026-09-13
- Linear: MOB-181
- GitHub: mob#110

## Context

`MobNodeView` on iOS previously ignored `fixed_width` and `fixed_height` on
Column and Row entirely. Column always applied `.frame(maxWidth: .infinity,
maxHeight: fillHeight ? .infinity : nil)` and Row only applied a
`fill_width`-driven `.frame(maxWidth: .infinity)`. Android was already
correct via `nodeModifier`.

The Box case had the same class of bug and was fixed in #104 (iOS honor
fixed-height boxes). Column and Row are the remaining two containers with
the same shape. The issue thread (mob#110) called out a precedence question
that #104 dodged because Box has no `fill_*` props: when a caller sets
`fixed_width: 100, fill_width: true` on a row, which wins? iOS and Android
have to decide the same way or a screen will render differently.

## Decision

**Fixed dims beat fill on iOS.** When both `fixed_width` and `fill_width` are
set on a Row, `fixed_width` wins. Same rule for `fixed_height` vs
`fill_height` on Column, and for `fixed_*` vs `layout_weight` on the flexing
axis (see `MobLayoutWeight` below). Rationale:

1. It's internally consistent with the Box #104 fix: fixed always wins on
   iOS, no exceptions.
2. SwiftUI applies chained `.frame` modifiers outside-in — an outer
   `.frame(maxWidth: .infinity)` after an inner `.frame(width: 100)`
   effectively hides the inner width. So the only way to make `fixed_width`
   actually apply is to suppress the outer max frame when the axis is
   pinned. That naturally makes fixed win.
3. A caller who sets both is almost always leaning on `fixed` and left
   `fill` in place; silently ignoring `fixed` was the bug being reported.

**Where the rule is applied.** Three places on iOS emit an outer
`.frame(maxWidth/maxHeight: .infinity)` around a container: the Column case
(fill_height), the Row case (fill_width), and `MobLayoutWeight.body` (any
node with a positive `layout_weight` on the parent's flex axis). All three
now check the corresponding fixed dim before applying the max frame, so a
`fixed_width` on a weighted Row child no longer expands to fill the parent
either. Without the `MobLayoutWeight` half, "fixed always wins" would be
false in that corner and the fix would be silently partial for flex layouts
that use `layout_weight` — the dominant Compose analogue for rows/columns.

At the time of MOB-181, Android's `nodeModifier` still let fill coerce fixed
(fill won). MOB-181 intentionally changed only iOS, leaving the divergence for
a follow-up.

MOB-233 supplied that follow-up on 2026-09-13. A fixed-width, full-height
column with a weighted scroll exposed an Android renderer failure, so generated
Android bridges now apply authored dimensions before cross-axis fills and
suppress a same-axis fill when a positive fixed dimension exists. The shared
contract is therefore fixed-over-fill for valid positive dimensions. See
`mob_new/decisions/2026-09-13-fixed-dimensions-wrap-fill-constraints.md`.

## Consequences

- iOS Column, Row and `MobLayoutWeight` now respect `fixed_width` and
  `fixed_height`; a `fixed_*` on the flexing axis wins over `fill_*` and
  over `layout_weight`.
- `fill_width` / `fill_height` remain the default behavior when no fixed dim
  is set on the corresponding axis.
- Since MOB-233, both renderers return the positive fixed dimension in the
  contradictory-props corner. Apps generated before that change retain the
  old Android behavior until their app-owned bridge is regenerated or updated.
- Source-contract regression: `test/mob/native_column_row_layout_test.exs`
  string-matches the Column, Row and `MobLayoutWeight` blocks so reverting
  any of them fails the test.
