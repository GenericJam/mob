# :scroll builds its content lazily (iOS)

- Date: 2026-09-02
- Status: accepted
- Implements: MOB-128, part of MOB-124
- Companion: `mob_new/decisions/2026-09-02-lazy-scroll-on-android.md`

## Context

The Android half of MOB-128 measured a 200-row screen at 134 ms of main-thread
work per update, 107 ms of it recomposition, against 45 ms for the whole
BEAM-plus-NIF pipeline. Making `:scroll` lazy took the main-thread cost to 82 ms
and made it flat in list length.

iOS has the same shape: `case .scroll:` wrapped its children in an eager
`VStack`/`HStack`, so every child of a scroll was built whether or not it was on
screen. Only the dedicated `lazyList` node type used `LazyVStack`.

## Decision

A column that is the direct content of a **vertical** `scroll` builds its
children with `LazyVStack` instead of `VStack`, **when that scroll opted in with
`lazy: true`**. Everywhere else the stacks stay eager.

**Opt-in**, matching Android, because laziness has observable consequences
beyond speed. Rows below the fold are never built, so they never register a
frame and `Mob.Test.element_frames` / `tap_id` cannot address them. And a
`LazyVStack`'s `contentSize` reflects only built rows and grows as you scroll,
so `nif_scroll_info`'s `contentSize - bounds` under-reports: `scroll_to(:bottom)`
under-scrolls and `screenshot_tour/3` truncates. `lazy_list` already makes that
trade explicitly; applying it silently to every scroll would change harness
behaviour under apps that never asked for it.

**Vertical only.** A `LazyVStack` under a horizontal `ScrollView` would be lazy
on the wrong axis — the vertical axis there is bounded and never scrolls, so
rows below the fold would never be built at all rather than built on demand.

**The column is made lazy, not the scroll's own stack.** Mob screens are written
`scroll > column > rows`, so the scroll's own stack has exactly one child and
making it lazy would buy nothing — the column underneath is the stack with 200
children.

**And the column is kept, not flattened away.** Android flattens the column and
uses its children as the list items, guarded by a check that the column's props
are layout-neutral. That guard is cheap there because props are a map. On iOS
`MobNode` exposes typed properties — padding, background, alignment, borders,
corner radius, `nativeViewId` — so an exhaustive "is this column neutral" test
would be a long list, and **missing one entry would silently drop something the
user can see**. Passing a `lazyContainer` flag down one level instead keeps every
modifier on the column exactly where it was.

`MobEitherStack` exists because SwiftUI cannot choose between `VStack` and
`LazyVStack` inside one expression. The `if` produces two different view
identities, which is fine here: `lazy` is fixed for a given node's position in
the tree, so it never flips for a live view.

## Status of the evidence

The change is **verified correct** — a 200-row screen renders identically to the
eager path on the simulator, including multi-line wrapping labels, text fields,
toggles and buttons.

The **win is not measured on iOS**. Android has `dumpsys gfxinfo framestats`,
which reports per-frame main-thread cost directly; iOS has no equivalent that can
be read from a script, and `set_root` dispatches to the main thread
asynchronously, so no BEAM-side instrument can see the work. The simulator runs
on a development Mac and is not representative of a phone, which is exactly the
mistake that made the first round of this epic's numbers worthless.

So this is parity-by-construction on the mechanism proven on Android, not an
independently measured iOS result. Measuring it needs main-thread instrumentation
on a physical device — a `CATransaction` completion timer around `setRoot` would
do it — and that is worth doing before claiming an iOS number.
