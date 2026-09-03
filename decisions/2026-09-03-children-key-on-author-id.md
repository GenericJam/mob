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

The epic said "the identity already exists on the wire". True, but it was not
reachable where `ForEach` needed it: on iOS the `:id` prop was read into
`MobNode` only as `nativeViewId`, and only for `native_view` nodes.
`accessibilityId` is a different prop. So iOS needed a `nodeId` on `MobNode`
first.

## Decision

Key children on the author's `:id` when present, position otherwise.

* **iOS** — `MobNode.nodeId` added and populated from `MOB_PROP_id` for every
  node type; `mobIdentifiedChildren/1` returns `[MobIdentifiedChild]`; all seven
  `childNodes` `ForEach` sites use it.
* **Android** — `mobChildKeys/1` mirrors it, built on the existing
  `MobNodeIdentity.keyFor/1`; `Column`/`Row` children go through `key()`, and
  `LazyColumn` uses `itemsIndexed(..., key:)`.

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

**Identity attaches to the repeated element, not to something inside it.** An
author who puts `:id` on a child of the repeated node gets positional keying
and no warning. That is worth documenting in the guides, and is the most
likely way this is mis-used.

**`:id` is coerced to a String in `Mob.Renderer`.** iOS reads it as an
`NSString` and ignores anything else; Android's `MobNodeIdentity` canonicalises
any JSON value. So `id: user.id` with an integer — the most natural way to
write it — keyed rows on Android and fell back to positional on iOS, silently.
Coercing atoms and numbers once, before the value leaves Elixir, makes the two
platforms agree by construction. Map and list ids still fall back to position on
both.

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
