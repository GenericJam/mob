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

**Not done here.** `MobTabView`'s `ForEach(Array(tabs.enumerated()), id: \.offset)`
still keys positionally — it iterates tab dictionaries rather than child nodes,
and a tab bar is a short, rarely reordered list. The `MobFrameTracker`
`.onChange(of: id)` workaround is kept: named nodes no longer need it, but
unnamed ones still fall back to position, so the hazard it guards is real for
them.
