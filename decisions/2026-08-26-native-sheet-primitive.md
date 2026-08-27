# Native Sheet primitive — presentation model, styling, exactly-once dismissal

- Date: 2026-08-26
- Status: accepted

## Context

Adding `Mob.UI.sheet/2` — a native modal bottom sheet (iOS `.sheet`,
Android Material 3 `ModalBottomSheet`) that composes ordinary Mob nodes
as content. Several parts of the design aren't obvious from the API
surface alone.

## Decision

### Presentation state lives in view/composable identity, not a boolean prop

Neither `MobSheetView` (iOS) nor `MobSheet` (Android) take a
`presented:` boolean prop. Instead, each holds local presentation
state (`@State private var isPresented = true` / `remember {
mutableStateOf(true) }`) seeded once when the composable/view first
appears at its position in the tree.

Both SwiftUI and Compose preserve that local state across re-renders
that keep dispatching to the same position (same case in a `switch`/
`when`, even though the `MobNode` object itself is rebuilt fresh from
JSON every render) — the same mechanism `MobToggle`/`MobSlider`
already rely on for user-driven state against a BEAM-pushed node. This
gives two required behaviors for free, with no explicit prop needed:

- **A rerender that still includes the sheet node updates its content
  without dismissing/re-presenting** — same identity, state preserved.
- **Removing the sheet node from the tree dismisses it** — the
  composable stops being called, its whole state (and the live
  presentation) is torn down.

### Exactly-once dismissal via a remembered flag, not just the platform callback

Both platforms' native dismiss callback (`.sheet(onDismiss:)` /
`ModalBottomSheet(onDismissRequest:)`) is expected to fire once per
user-initiated dismissal, but a local `dismissSent` flag guards the
actual BEAM-facing send anyway. Cheap insurance against any platform-
specific double-invocation edge case, and it's the literal shape
requested for the Android side — keeping both platforms symmetric.

### background/corner_radius are NOT threaded through the standard modifier pipeline

Every other node type gets `background`/`corner_radius` baked into its
modifier by the generic pipeline (iOS: read directly onto
`node.backgroundColor`/`node.cornerRadius`, which every case already
does; Android: `nodeModifier(node.props)`, applied centrally in
`RenderNodeInner` before dispatch). For most types that's correct — a
plain `.background()`/`.clip()` is exactly what a `Box`/`Row`/etc.
wants.

Sheet can't reuse that path. `ModalBottomSheet` (and SwiftUI's
`.presentationBackground`/`.presentationCornerRadius`) own their own
container paint and corner shape — the same reason Android's `Button`
already reads `background`/`corner_radius` directly instead of via
modifier (`ButtonDefaults.buttonColors`/`shape=`). Passing the
already-baked modifier straight into the sheet would double-apply:
once from the outer modifier's full-rect background/clip, once from
the sheet's own top-corners-only shape — visible as double-painted
background or clipped corners that don't match the requested radius.

Fix, symmetric on both platforms:
- iOS: `MobSheetView` reads `node.backgroundColor`/`node.cornerRadius`
  directly for `.presentationBackground`/`.presentationCornerRadius`;
  the sheet's *content* (children) gets no separate modifier — SwiftUI
  never had a "baked-in" modifier to begin with (see `MobNode.h`: every
  node type reads these two properties generically, but nothing
  upstream of `MobSheetView` applies them as a `.background()`/`.clip()`
  the way Android's central `nodeModifier` does).
- Android: `MobSheet` receives the dispatch call *without* the
  `m`-derived modifier (`MobSheet(node)`, not `MobSheet(node, m)`), and
  builds its own content modifier from `node.props - listOf("background",
  "corner_radius")` before passing it to `nodeModifier`. A structural
  lint (`MobNew.Templates.Lint.sheet_content_modifier_not_double_applied/1`
  in `mob_new`) guards both halves of this against regression, since
  it's not something a compiler catches — code that double-applies
  still compiles and runs, it just looks wrong.

### iOS scrim opacity: documented limitation, not a bug to "fix" later

Android applies the requested `:scrim` color (including alpha) exactly
via `ModalBottomSheet`'s `scrimColor` param. iOS's `.sheet` presentation
owns its dimming layer with no public API to configure its opacity —
supported SwiftUI APIs leave it system-black at a fixed alpha. The only
way to force exact opacity is private `UIViewController`/presentation-
controller hierarchy manipulation, which this framework does not do
(same policy as everywhere else native internals are touched only
through documented APIs). Documented in `Mob.UI.sheet/2`'s moduledoc
and in the mob_new CHANGELOG rather than tracked as an open bug.

### Android medium-only short-content fix

Material 3's `ModalBottomSheet` can omit the `PartiallyExpanded` anchor
entirely when content measures shorter than half the viewport. A
medium-only sheet (`detents: [:medium]`) rejects `Expanded` via
`confirmValueChange`, so a short-content medium-only sheet would have
no valid anchor to land on and stay hidden. Content is wrapped in
`BoxWithConstraints`; when `mediumOnly` is true, a `heightIn(min =
maxHeight * 0.5f + 1.dp)` forces just enough height for Material 3 to
compute a real anchor. Full medium+large sheets are untouched — this
only kicks in for the medium-only case, and never allows `Expanded`
(the fix is sizing, not a detent-contract workaround).

Verified via a generated-project Android instrumentation test
(`MediumOnlySheetTest`, `mob_new`) — 1/1 pass on a real emulator with
deliberately short content and `detents == ["medium"]`. Note: a
negative-control check (temporarily disabling the fix) did not
reproduce a clean failure on the specific emulator/Compose-BOM
combination used for verification — the fix follows the requested
spec exactly and the positive case is real-device-confirmed, but the
without-fix failure mode wasn't independently reproduced in this
environment. Worth another look if this Material 3 behavior surfaces
again on a different device/BOM combination.

## Consequences

- Adding a `presented:`-style prop later (e.g., to let BEAM force-close
  a sheet without a full tree diff) would need a real prop read in
  addition to the identity-based default, not a replacement for it.
- The lint check only catches the *specific* double-application shape
  (raw `m` threaded through, or an unstripped `node.props` build) — a
  sufficiently different refactor of `MobSheet`'s modifier construction
  could still double-apply without tripping it. It's a regression guard
  for this exact class of mistake, not a general correctness proof.
