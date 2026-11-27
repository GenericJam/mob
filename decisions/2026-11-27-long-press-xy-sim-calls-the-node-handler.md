# On the iOS simulator, long_press_xy calls the Mob node's on_long_press

- Date: 2026-11-27
- Status: accepted

## Context

`Mob.Test.long_press_xy/4` on the iOS simulator searched the hit view and its
ancestors for a `UILongPressGestureRecognizer` and forced it through
`_setState:`. Mob nodes get their long press from SwiftUI's
`onLongPressGesture` (`mobGestures`, MobRootView.swift), which creates no such
recognizer, so every Mob node returned `{:error, :no_long_press_recognizer}`
(MOB-572, found driving the mob_mishka gallery). Its fallback,
`accessibilityActivate`, was a tap rather than a long press, and it reported
`:ok` whether or not anything reacted.

Real touches cannot be made in-process. The simulator drops synthetic IOHID
events (the reason `tap_xy` uses accessibility activation), and SwiftUI does
not expose a long press as an accessibility action. The AX elements under a
row are its Texts, and they carry no identifier.

## Decision

When the hit chain has no UIKit recognizer, the simulator NIF:

1. Takes the tree on screen (`MobViewModel.shared.displayedRoot`), only when
   the hit window belongs to the shared model's scene: the element frame
   registry holds only the default window's frames (MOB-245).
2. Among the nodes of a type that gets `mobGestures` (column, row, wrap, box,
   label, icon, anchored) with both `onLongPress` and a `nativeViewId`
   (`:id`), picks the one with the smallest frame in the element frame
   registry (MobFrameTracker, what `element_frames/1` reads) that contains
   the point. Of equal frames the later node in the tree wins. A button,
   field, slider, toggle, image or scroll carries the block but never runs
   it on a real press, so it is not a candidate.
3. Calls that node's `onLongPress` block, the same block the SwiftUI gesture
   calls.

The result uses `tap_xy`'s observation model. `:ok` means the UI event counter
moved, `{:error, :no_effect}` means something fired and no event arrived, and
`{:error, :no_long_press_recognizer}` means nothing at the point takes a long
press. The `accessibilityActivate` fallback is gone.

The hit view chooses between the screen and a presented sheet. If it is
outside the window root controller's view, only nodes inside a `:sheet` are
candidates; otherwise only nodes outside one are. So a point on a sheet cannot
reach the row behind it.

An open `:anchored` panel whose owner has `onTap` draws a full-window dismiss
scrim under every open panel (`MobAnchoredPanelHost`). While one is open
(an `:anchored` node with two children and `onTap`, outside any `:sheet`), a
point on the screen is searched for only inside the open panels
(`children[1]` of every open `:anchored`), so a press on a row under the
scrim reaches nothing, as a real one would.

## Consequences

- A long-press node needs an `:id` to be reachable by coordinates. That is
  also the documented way to find its coordinates (`element_frames/1`).
- This exercises the handler routing (`on_long_press` → `{:long_press, tag}` →
  `handle_info`), not SwiftUI's gesture recognition. A layout bug that stops
  the real gesture from reaching a node, such as an overlay inside the same
  SwiftUI tree swallowing touches, is not caught. Real-touch checks still go
  through XCUITest (`agent-device`).
- Occlusion is only modelled for sheets and the anchored scrim. A panel
  without a scrim, a fixed header over a row scrolled under it and the
  keyboard are not seen, and the node beneath still fires. The frame is not
  the gesture's hit shape either: a `Color.clear` background, or the frame a
  `layout_weight` expands, can give `:ok` where a real press does nothing.
- The scrim check reads the tree, not the screen. An `:anchored` whose anchor
  is not laid out (a lazy row scrolled out of range) publishes no panel and
  no scrim, yet still narrows the search to its panel, so a point on the
  screen then reaches nothing.
- `duration_ms` is not waited on the simulator, and a press shorter than the
  gesture's 0.5 s minimum still fires.
- On a physical device the IOHID path is unchanged and still reports on
  acceptance.
