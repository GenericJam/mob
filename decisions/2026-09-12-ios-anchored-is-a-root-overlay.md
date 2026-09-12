# iOS `:anchored` panels are drawn at the root, positioned by the Android arithmetic

- Date: 2026-09-12
- Status: accepted
- Issue: MOB-190 (part of MOB-188)

## Context

The Mishka Chelekom port introduced `:anchored`, a node whose first child is an
in-flow trigger and whose second child is a panel that must float over the
page (popover, tooltip, menu, select, combobox, tree select, context menu,
preview card). Android renders the panel in its own window through
`androidx.compose.ui.window.Popup`, placed by `MobAnchoredPositionProvider`,
a transliteration of the web engines' `positionPopup()`.

iOS had no such node type. `mob_nif.m` mapped unknown type strings to nothing,
which left `nodeType` at its zero value, `MobNodeTypeColumn`, so every anchored
node quietly rendered as a VStack of `[trigger, panel]`: the stacked accordion
the type exists to replace. No error, no blank, and `Mob.ScreenCase`'s
renderable set is the union of both platforms' whitelists, so a green unit
suite could not see it.

Three SwiftUI mechanisms were considered:

1. `.overlay(alignment:)` plus `.offset` on the anchored node. Draws inside
   the node's own subtree, so any ancestor with `corner_radius` (a clipping
   Box) or a vertical `Scroll` clips it. That clipping is the measured
   failure that made `:anchored` a node type rather than a positioned Box.
2. `.popover(isPresented:attachmentAnchor:)`. Right name, wrong tool: on
   iPhone it adapts to a sheet, brings its own arrow and dimming, and
   dismisses itself on an outside tap. The BEAM owns open and closed here; a
   window that closes on its own desynchronises from the screen's assign.
3. An anchor preference collected at the root. The anchor child publishes
   its bounds with `.anchorPreference(value: .bounds)`; `MobRootView`'s ZStack
   resolves them through `.overlayPreferenceValue` and draws the panel there,
   above every slot, Box and Scroll.

## Decision

Option 3. `MobAnchoredView` renders the anchor in flow and publishes an entry
(owner node, panel node, bounds anchor). `MobAnchoredPanelHost`, attached to
the root ZStack before `.ignoresSafeArea`, measures each panel once and places
it with `MobAnchoredPosition.origin/5`, a line-for-line port of the Android
provider: mirror side and align for RTL, flip the main axis only when the
requested side has no room and the opposite one does, apply the raw nudge,
then clamp to the window (edge padding plus the safe area) only while the
anchor is on screen. `on_tap` on the node is the outside-tap dismiss request:
a clear full-window shape under the panel reports it; nothing closes itself.

The code lives in `ios/MobAnchored.swift`. `MobRootView.swift` was already
past swiftlint's 3000-line limit, and the generated `build.zig` globs every
`ios/*.swift`, so a new file costs nothing downstream.

## Consequences

- Both platforms now agree on placement by construction. Any future change to
  the arithmetic has to land in both files; do not "improve" one side.
- A panel inside a presented `:sheet` is not seen by the root host: sheets
  are presented in a separate window and their preferences do not propagate
  to the root ZStack. No Mishka component nests a popover in a sheet today;
  when one does, the sheet content view needs its own host.
- The first layout pass positions a zero-size panel, so the panel is drawn
  at opacity 0 until measured. One frame, invisible, but a test that reads
  `element_frames` immediately after opening may see the pre-measure position.
- `Anchored` is on `priv/tags/ios.txt` only until the Android bridge template
  (mob_new, MOB-189) carries `MobAnchored`; the sigil reports it as iOS-only
  until then, which is the truth.
