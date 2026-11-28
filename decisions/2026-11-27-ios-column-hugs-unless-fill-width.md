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

- Breaking for iOS-only screens that relied on a Column filling. It ships in
  a 0.9.x patch release, so every app on `~> 0.9.x` picks it up at its next
  `mix deps.update mob`; the CHANGELOG entry is tagged BREAKING for that
  reason. No flag: Android has always laid Columns out this way, and a flag
  would keep the wrong iOS layout alive as a second convention. What moves,
  each with the fix Android already needed:
  - A Column that paints a `background` or carries an `on_tap`, and holds
    only hugging children (plain Text, Rows without `fill_width`,
    fixed-size items), now covers only its content: the background and the
    tap area shrink with it. (iOS draws `border` and `corner_radius` on a
    Column only when it is weighted, and a weighted Column fills its share.)
    Add `fill_width={true}` to the Column.
  - A Row without `fill_width` takes its width from its children
    (`MobRootView.swift`, Row case), so a Row whose width came from a Column
    child shrinks too, background and tap area included. Add `fill_width`
    to the Row.
  - In a Row, siblings after a Column now sit next to its content instead of
    at the far edge. Give the Column `weight`, or put a flexible Spacer
    before the siblings that belong at the end.
  - Only the node a screen slot hosts is a screen root. A Column that is the
    content of a sheet, a lazy-list row or a tab hugs like any other. (A
    tab's background is repainted across the whole tab by `MobTabView`, so
    there only the tap area changes.)
  - Existing mob_new-generated apps: the dice screen's stat cards shrink to
    their text. They need `weight: 1` in `stat/2` and `fill_width: true` on
    the stats Row, which mob_new #132 gives new apps. The CHANGELOG entry
    says so, because existing apps do not read mob_new's changelog.
- Columns side by side in a Row no longer split the row evenly on iOS. Use
  `weight`. Until MOB-569 (#257) lands, iOS `MobLayoutWeight` makes every
  weighted child equally flexible, so weights split evenly; MOB-569 divides
  by ratio, as Compose's `weight()` does. `fill_width` on several Row
  children is not portable: on Android the first one takes the whole row.
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

Re-verified after rebasing onto master 60f8cdb (MOB-566, MOB-567, MOB-568,
MOB-572), same simulator, demo dice screen updated as mob_new #132 does:
the six pages above, toured against a build of 60f8cdb alone, differ in the
same viewports as before and are pixel-identical to the e6dc1d9-based tour
of this change. The dice cards are two equal halves on both builds, and the
other demo screens are identical apart from the RPS history's "N min ago".
