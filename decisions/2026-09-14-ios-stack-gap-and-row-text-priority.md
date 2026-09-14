# iOS stack gap and row text priority

- Date: 2026-09-14
- Status: accepted
- Linear: MOB-234

## Context

Mob exposes `gap` on Row and Column, and the renderer resolves its tokens before
serializing the tree. The iOS native prop table did not contain `gap`; both the
`HStack` and the eager and lazy `VStack` paths hard-coded zero spacing. Review
also found that the current Android generator omitted the prop from Row and
Column, so MOB-234 closes both sides in `mob` and `mob_new`.

SwiftUI also assigns Text and a flexible Spacer the same default layout
priority. In a Row with `[title, spacer, detail]`, the stack could compress the
labels while the Spacer still owned removable slack. Short labels then wrapped
even though the row had enough total room. Forcing Text to its fixed ideal size
would avoid compression but could overflow genuinely constrained rows.

## Decision

- Parse `gap` once into `MobNode.gap` and pass it to Row and both Column stack
  implementations. Zero remains the default, preserving existing trees that do
  not set the prop.
- Give an unweighted Text node layout priority `1` only when it is a direct
  child of a Row that contains a flexible Spacer. This makes priority relative
  to the Spacer without changing Rows that have no flexible Spacer, authored
  weight allocation, vertical space in a Column, or text nested in a container.
- Keep explicit `weight` behavior outside this rule. `MobLayoutWeight` still
  owns authored flex sizing; the text priority only changes which unweighted
  sibling shrinks first.

## Consequences

- `gap` now has the documented cross-platform behavior for Row and Column,
  including a lazy Column inside a vertical scroll.
- Existing Android apps must regenerate or copy the `mob_new` bridge change;
  updating only the runtime dependency does not replace app-owned Kotlin.
- Unweighted direct Row labels preserve their ideal width ahead of flexible
  Spacers, but can still truncate or wrap when the non-Spacer content truly
  exceeds the row.
- A label nested inside another container keeps that container's layout
  contract; priority does not jump across the container boundary.

## Verification

A disposable Crosscourt build removed its fixed gap node, set the drawer
header Row's `gap` to 9, and placed a flexible Spacer between the mode title
and detail label. On an iPhone 17e simulator, the native drawer rendered the
header spacing and kept `PLAY ON SCREEN` and `HOT SEAT · 3 BOTS` on one line.
The signed build also installed successfully on the connected iPhone SE; the
phone was locked when the post-install launch check ran and disconnected before
it could be retried.
