# iOS Column hugs its content unless `fill_width` is set

- Date: 2026-11-27
- Status: accepted
- Linear: MOB-564

## Context

The iOS Column case in `ios/MobRootView.swift` applied
`.frame(maxWidth: .infinity)` whenever the column had no `width`. It never
read `fill_width`, so `fill_width={false}` did nothing. The guides even listed
`true` as the Column default.

Android disagrees. The generated bridge composes a Column with
`nodeModifier`, which adds `fillMaxWidth()` only for `fill_width: true`;
otherwise a Compose Column wraps its widest child. The screen root is the
exception: `MainActivity` hosts it with `Modifier.fillMaxSize()`.

The mob_mishka composites were written against Android and broke on iOS:

- Tab triggers, each a Column in the strip's HStack, were all equally greedy.
  The strip split its width evenly, so long labels wrapped mid-word
  ("Overvie/w") and short ones got slack.
- `MishkaEmptyState` centres its indicator and action row with
  `<Box align={:center}>`. The Columns inside filled the Box, leaving nothing
  to centre.
- `MishkaAnchor`'s underline is drawn under a Column inside
  `<Box fill_width={false}>`. The Column filled, so the underline ran the
  full card width.
- The calendar agenda's time Column shared its row evenly with the weighted
  title Column.

IOS_TODO 6 had already fixed the same gap for Box (`fillWidthSet` /
`fillWidth`). Box defaults to filling on both platforms; Column does not.

## Decision

An iOS Column fills its parent's width only when `fill_width` is true, or
when it is the node a screen slot hosts (`MobNodeView(..., screenRoot:
true)`). Otherwise it hugs its widest child. `width` still beats both, as
decided in `2026-09-11-column-row-fixed-dims-precedence.md`.

The root keeps filling because Android's root does (`fillMaxSize`). Without
the exception, a root `<Column background=...>` holding only Text would
shrink to its text on iOS and nowhere else. Only the width is matched. The
root column's height behaves as before: it grows into the screen when a child
is flexible (`fill_height`, a flexible Spacer, `weight`) and otherwise hugs.
Matching `fillMaxSize`'s height half would change every root column's
background extent, which is out of scope here.

Nothing else is special-cased. A child that fills (a Box, a Button, a
Divider, a centred Text, or a `fill_width` Row or Text) widens a hugging
VStack to the proposed width, as `fillMaxWidth` widens a wrapping Compose
Column. So `scroll > column(padding) > boxes` pages look the same as before.
A Column whose children all hug now hugs as well, which is what Android
always did.

The Column directly under a `lazy: true` vertical Scroll renders as a
`LazyVStack`, which is flexible in width, so it still fills without
`fill_width`. Android fills there too when it flattens a bare Column into a
`LazyColumn`, but takes its eager path (and hugs) when that Column carries
any other prop. That gap predates this change and is left alone.

## Consequences

- Breaking for iOS-only screens that relied on a Column filling. A Column
  that paints a `background` or carries an `on_tap`, and holds only hugging
  children (plain Text, Rows without `fill_width`, fixed-size items), now
  covers only its content: the background and the tap area shrink with it.
  (iOS draws `border` and `corner_radius` on a Column only when it is
  weighted, and a weighted Column fills its share.) Migration: add
  `fill_width={true}` to that Column. Android already needed it, so the
  change brings the two renderers into line.
- Columns side by side in a Row no longer split the row evenly on iOS. Use
  `weight` (which iOS still turns into an even split, `MobLayoutWeight`).
  `fill_width` on several Row children is not portable: on Android the first
  one takes the whole row. The mob_new dice screen's two stat cards were the
  one case in the generated app; mob_new gives them `weight: 1`.
- `align` on a Column is still not read on iOS; the VStack keeps `.leading`.
  This change did not touch it.
- Source-contract test: `test/mob/native_column_row_layout_test.exs`
  ("iOS column hugs its content unless fill_width or screen root") fails if
  the unconditional `maxWidth: .infinity` comes back or the root stops
  passing `screenRoot: true`.

## Verification

iPhone 18 Pro simulator, mishka_ios_demo (mob_new 0.6.21, mob_mishka 0.1.6)
built against this change on top of master at MOB-563 (e6dc1d9, which
includes MOB-562). All 66 gallery pages toured with `scripts/ios_tour.exs`
and compared pixel by pixel with a tour of e6dc1d9 alone: 60 pages are
identical. Changed, all for the better: tabs (labels on one line, underline
under the active label), empty_state (indicator and actions centred;
"Leading" text beside the indicator), nav_link (anchor underline as wide as
"mishka.tools"), calendar (agenda time cell no longer takes half the row),
toolbar (burger bars centred in their box), tooltip (open bubbles land where
`side`/`align` put them against their trigger instead of clamped to the
screen's leading edge: a bubble Column used to fill the anchored panel's
width cap, so the panel measured window-wide). The demo's other screens
(home, gallery, list, audio, storage, text, webview) are identical; the
dice screen's stat cards shrank to their text until the mob_new change
above.
