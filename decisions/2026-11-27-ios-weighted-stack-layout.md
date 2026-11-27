# iOS rows and columns with a weight use a custom Layout

- Date: 2026-11-27
- Status: accepted
- Ticket: MOB-569

## Context

Compose's `Modifier.weight()` measures a Row's or Column's unweighted children
first, then divides the space left over, after spacing, between the weighted
children by ratio. Each weighted child gets exactly its share.

iOS only made a weighted child flexible: `MobLayoutWeight` wraps it in
`.frame(maxWidth: .infinity)` (or `maxHeight` in a Column) and leaves the rest
to the HStack / VStack. A stack gives its leftover to its flexible children
evenly and has no way to read a ratio. `layoutPriority` does not help either,
because it orders children rather than proportioning them. So `weight={0.35}`
beside `weight={0.65}` drew two halves. MishkaSkeleton's short last line, which
is a weighted bar beside a weighted Spacer, came out at half width, and any 1:2
split came out 1:1.

## Decision

A Row or Column with at least one child that has an effective `weight` is laid
out by a custom SwiftUI `Layout`: `MobWeightedRowLayout` /
`MobWeightedColumnLayout` in `ios/MobWeightedStack.swift`. A weight is effective
when it is positive and no fixed size is set on the main axis, since fixed
beats weight (`2026-09-11-column-row-fixed-dims-precedence.md`). Every other
stack is still `HStackLayout` / `VStackLayout`. The renderer switches between
the two through `AnyLayout`, so children keep their identity, and their
`@State`, when a weight appears or goes away.

The layout works as follows:

- **Finite main-axis proposal.** It first measures the unweighted children in
  source order. Each is offered its ideal main-axis size, capped at what is
  left. The space left after them and the gaps is then split by
  `weight / totalWeight`, and each weighted child is offered exactly its
  share. `MobLayoutWeight` is still applied to weighted children: its flexible
  frame lets a child accept the share, and it repaints the child's background
  and border on that frame. A weighted child that cannot shrink to its share
  (a share of 0 included) keeps its own size, and the next sibling is placed
  after it. Compose clips such a child to its share instead; overlapping the
  neighbour, visually and for taps, would be worse than overflowing the row.
- **Ideal (`nil`) or unbounded proposal.** There is no leftover to divide, so
  every child is measured with that same proposal, as an HStack / VStack would
  do. Placement keeps the ideal arrangement rather than splitting the ideal
  total again by ratio. Re-splitting it would hand a weighted child less than
  its own ideal size and make it overlap its neighbour.
- **Flexible Spacer.** A Spacer with no positive `size`, inside a weighted
  stack, counts as `weight: 1`, as Android's `mobChildWeight` does. A flexible
  Spacer on its own does not make a stack weighted.
- **Spacer axis.** `layoutProperties.stackOrientation` is set, so a Spacer is
  flexible only along the stack's axis, exactly as in an HStack. Without it, a
  weighted Spacer took the whole proposed height, and the row grew to match
  (300pt instead of 8 in the host test).
- **Cross axis.** Children are aligned on the row's `align` guide
  (top / centre / bottom / last-text-baseline) and on `.leading` in a column,
  as before.
- **Right-to-left.** SwiftUI mirrors a custom Layout's placement in a
  right-to-left environment, the same way it mirrors an HStack, so the layout
  does not mirror itself. The host test checks the absolute mirrored frames
  (the first child at the trailing edge).

### Where this departs from Compose

Compose measures an unweighted child against all the space left. A child that
fills (`fillMaxWidth`) therefore takes everything, and the weighted children
get nothing. iOS caps an unweighted child at its ideal size instead.

The reason is that an iOS Column fills its parent's width whether or not
`fill_width` is set. That is MOB-561 RC1, which is open separately. Measured
Compose's way, every Column sitting beside a weighted sibling (MishkaCalendar's
agenda rows, for example) would starve that sibling to zero width. With the
cap, the weighted sibling keeps a share as long as the Column's ideal width
(its longest line, unwrapped) fits in the row. A Column whose ideal width is
wider than the row (long wrapping text) still takes the whole row and leaves
the weighted sibling 0, as in Compose; the old HStack split that case evenly.
The cost of the cap is that an unweighted `fill_width` child in a weighted Row
is narrower on iOS than on Android.

## Alternatives rejected

- **Ratio frames on each child.** A child cannot see its siblings' weights or
  the parent's leftover space, so `.frame(maxWidth:)` cannot express a ratio.
- **A GeometryReader in the stack.** It sizes the stack to the whole proposal
  and needs a second pass to place the children. It also breaks ideal sizing
  inside scroll views.
- **The custom Layout for every Row and Column.** It would change measurement
  for every unweighted stack in every app, including the text-priority rule in
  `2026-09-14-ios-stack-gap-and-row-text-priority.md`, which relies on HStack's
  `layoutPriority` handling. Only stacks that ask for weights take the new path.

## Consequences

- Weights now divide by ratio on both platforms. `guides/components.md` no
  longer tells authors to use equal weights only.
- `layoutPriority` has no effect inside a weighted stack. The text-priority
  rule is not needed there, because unweighted labels are measured at their
  ideal width before any weighted child or Spacer gets space.
- A lazy Column (`lazy: true` inside a vertical scroll) stays a LazyVStack and
  ignores weights. It has no bounded height to divide.
- `test/native/weighted_stack_test.swift` compiles the shipped
  `ios/MobWeightedStack.swift` on macOS and lays out real SwiftUI views with
  it. It fails if the split goes back to an even one.
  `test/mob/native_layout_weight_test.exs` checks that the renderer routes
  weighted Rows and Columns to this layout.
