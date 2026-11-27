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

1. Takes the tree on screen (`MobViewModel.shared.displayedRoot`).
2. Picks the innermost node that has both `onLongPress` and a `nativeViewId`
   (`:id`) and whose frame in the element frame registry (MobFrameTracker,
   what `element_frames/1` reads) contains the point.
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

## Consequences

- A long-press node needs an `:id` to be reachable by coordinates. That is
  also the documented way to find its coordinates (`element_frames/1`).
- This exercises the handler routing (`on_long_press` → `{:long_press, tag}` →
  `handle_info`), not SwiftUI's gesture recognition. A layout bug that stops
  the real gesture from reaching a node, such as an overlay inside the same
  SwiftUI tree swallowing touches, is not caught. Real-touch checks still go
  through XCUITest (`agent-device`).
- `duration_ms` is not waited on the simulator, and a press shorter than the
  gesture's 0.5 s minimum still fires.
- On a physical device the IOHID path is unchanged and still reports on
  acceptance.
