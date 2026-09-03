# Children key on the author's `:id`, not on position

- Date: 2026-09-03
- Status: accepted
- Implements: MOB-127, part of MOB-124
- Cross-repo: this and the matching `mob_new` change are one issue

## Context

Nine `ForEach` sites in `ios/MobRootView.swift` used `id: \.offset`, and the
Compose bridge's `LazyColumn` used `items(children)` with no `key`. Both mean
positional identity: insert or delete a row and every later row becomes a
different view to the platform, so it is rebuilt and its state discarded rather
than moved.

The consequences are not only performance. A `text_field`'s edit buffer lives
in `remember`, tied to the composition slot, so on Android prepending a row
moved the typed text to a different row. `MobFrameTracker` carries an
`.onChange(of: id)` specifically to paper over the same problem for the frame
registry — the workaround is in the file, with a comment describing the hazard.

The epic said "the identity already exists on the wire", and on iOS it was
already reachable: `mob_nif.m` has always read `:id` into `MobNode.nativeViewId`
for every node type — only `nativeViewProps` is gated on the node being a
native_view, and `MobFrameTracker` has always read `nativeViewId` for all node
types. The name is historical and misleading, which is why a first attempt at
this change added a second, identical `nodeId` property before review caught
it. `accessibilityId` is a genuinely different prop (`:accessibility_id`).

## Decision

Key children on the author's `:id` when present, position otherwise.

* **iOS** — `mobIdentifiedChildren/1` returns `[MobIdentifiedChild]`, reading
  the author id from the existing `MobNode.nativeViewId`; all seven `childNodes`
  `ForEach` sites use it, and `mobIdentifiedTabs/1` does the same for the tab
  bar, whose `ForEach` also subscripts `childNodes`.
* **Android** — `mobChildKeys/1` mirrors it. Deliberately NOT built on
  `MobNodeIdentity.keyFor/1`: that canonicalises any JSON value where iOS reads
  only an `NSString`, and it raises on an unknown value type — acceptable for
  the one sheet per screen it was written for, not on a path that runs for every
  child of every container. All seven containers are keyed (`column`, `row`,
  `box`, both `scroll` axes, the sheet body, and `LazyColumn` via
  `itemsIndexed(..., key:)`).

Three details that are easy to get wrong:

**Authored ids and positions are prefixed differently** (`i\x01…` vs `p\x01…`),
so an author id of `"3"` cannot collide with position 3 and silently merge two
unrelated rows.

**A duplicate id folds in its position** rather than emitting two equal keys.
SwiftUI misbehaves quietly on duplicate `ForEach` ids and Compose *throws* on
duplicates in a lazy list — turning a cosmetic problem into a crash would be
worse than the bug being fixed.

**Android keys are plain `String`s.** `LazyColumn` keys must survive
saved-instance state, and `MobNodeIdentityKey` is a data class, not Saveable.

`Modifier.weight` is resolved in the layout scope before `key()` is entered:
`forEachIndexed` is inline so `ColumnScope` survives, but `key()`'s block is a
plain composable lambda with no scope of its own.

## Consequences

Verified on the Pixel 8 emulator with four rows, each a `text_field`, and a
button that prepends a row. Typed `ZZZ` into "charlie", prepended — `ZZZ`
stayed with charlie as it moved down. The same screen with the `:id` on the
inner `text_field` instead of on the repeated row keys positionally, and the
typed text is lost; that is the before-behaviour, on the same build.

**Numeric `:id` is coerced to a String in `Mob.Renderer`.** iOS reads `:id` as
an `NSString` and ignores anything else, so `id: user.id` with an integer keyed
rows on Android and fell back to positional on iOS. Numbers only: `:json.encode`
already stringifies bare atoms, so widening to atoms would change nothing for
them while turning `true`/`false` from a JSON boolean both platforms correctly
reject into the real id `"true"`, and `nil` into `""`. Map and list ids still
fall back to position on both.

The coercion is `prepare_props`-scoped, so it does **not** reach ids nested
inside prop values — `tabs: [%{id: 1}]` still degrades to positional keying and
a mismatched `.tag`. Worth fixing if tab ids are ever authored numerically.

**`MobTabView` is keyed too.** An earlier version of this document claimed its
`ForEach` "iterates tab dictionaries rather than child nodes" and left it
positional. That was wrong — the body subscripts `node.childNodes`, so toggling
a conditional tab shifted every later tab's entire content subtree into its
neighbour's identity.

**`MobFrameTracker`'s `.onChange(of: id)` is kept, for a different reason than
first written.** A tracker only exists when the node has an id, so unnamed nodes
have no tracker and the original "unnamed nodes still shift" rationale was
wrong in both directions. What remains is the duplicate-id fallback: those keys
embed a position, so they genuinely do move between nodes when a duplicated
id's list shrinks.

**`on_end_reached` now fires on list content replacement (iOS).** Under
positional keying the first N views survived a content swap and `.onAppear` did
not re-fire. With author ids, replacing a list's contents gives every row a new
identity and the last row's `.onAppear` runs. A search screen that replaces
results per keystroke now fires a pagination request per keystroke where it did
not before. Android's index-based `derivedStateOf` already behaved this way, so
this is convergence rather than a new divergence — but it is a behaviour change
and it is not covered by a test.

**Identity attaches to the repeated element, not to something inside it.** An
author who puts `:id` on a child of the repeated node gets positional keying and
no warning. This is the most likely way the feature is mis-used and it cost a
round of debugging while writing the test screen for it.
