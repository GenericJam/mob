# iOS physical-device IOHID tap injection is accepted but never delivered

- Date: 2026-08-09
- Status: proposed (investigation; no fix in this change)

## Context

Driving a physical iPhone (iOS 26.5.2) over dist, `Mob.Test.tap_xy/3` returned
`:ok` for every coordinate and nothing ever happened on screen. Timeboxed
investigation of why, recorded so the next attempt doesn't restart from zero.
The honesty fix that makes this visible instead of silent is
`2026-08-09-tap-xy-reports-observed-effect.md`; this file is about the
underlying delivery failure.

## What the code does today

`mob_send_touch_phase` (`ios/mob_nif.m`) on iOS 26+:

1. `dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent")`
2. builds a **bare finger event** with normalized coords
   (`pt / UIScreen.mainScreen.bounds.size`), `eventMask = Range|Touch|Position`,
   `tipPressure` 1.0/0.0, `range`/`touch` booleans keyed to the phase
3. `((HandleFn)objc_msgSend)(app, @selector(_handleHIDEvent:), hidEvent)`
4. reads back `[app _touchesEvent]` and, *if* `allTouches.count > 0`, calls
   `[window sendEvent:ev]`
5. **returns `YES` unconditionally**

## Findings

1. **The return value never described delivery.** Step 5 returns `YES` whenever
   the symbol resolved and the selector exists. Step 4 already contains the
   evidence of failure — `allTouches.count` is 0 — and the code logs it, then
   ignores it. This is the whole reason the false `:ok` reached callers. Cheapest
   possible next step: return `NO` when `allTouches.count == 0` after
   `_handleHIDEvent:`. That converts a silent lie into a typed error with no new
   API surface, and gives a device-side signal to iterate against.

2. **A bare finger event is the wrong shape.** UIKit's HID path expects a *parent*
   `kIOHIDEventTypeDigitizer` event with finger events appended as children
   (`IOHIDEventCreateDigitizerEvent` + `IOHIDEventAppendEvent`), not a lone
   finger event. Injecting the child directly is the most likely reason UIKit
   ingests it and produces no `UITouch`. This is the shape every working
   out-of-process touch injector uses.

3. **Sender/context routing is unset.** `_handleHIDEvent:` routes by the window's
   context id. Nothing in the current path sets a sender id on the event
   (`IOHIDEventSetSenderID`). The `window_info` diagnostic already in
   `nif_tap_xy` — it probes `_contextId` / `_windowContextID` / `contextId` /
   `_displayID` on the key window — is a leftover from a previous run at this
   and is exactly the value that would need to be attached.

4. **The manual `UITouch` path may be revivable on iOS 26.** The file's own
   runtime enumeration (dated 2026-04-21, in the comment above the private
   category declarations) records that iOS 26 *promoted* `setWindow:`,
   `setView:`, `setPhase:`, `setTimestamp:` and `setTapCount:` to public, leaving
   only `_setLocationInWindow:resetPrevious:` private, and that `_touchesEvent`
   still exists on `UIApplication`. The `#if` structure sends iOS 26 down the
   HID path unconditionally, so the promoted-setter variant of the `< 26` path
   has never actually been tried on 26. It is a small, self-contained experiment.

## Concrete next steps, cheapest first

1. Make `mob_send_touch_phase` return `NO` when no `UITouch` materialised
   (`[app _touchesEvent].allTouches.count == 0`). Pure honesty, no risk.
2. Try the promoted-public-setter `UITouch` + `[window sendEvent:]` path on
   iOS 26 (finding 4). Guard with `respondsToSelector:` as the existing code
   does; fall through to HID if it doesn't take.
3. If 2 fails, build the parent digitizer event and append the finger
   (finding 2), and set the sender id from the window context id the
   `window_info` probe already retrieves (finding 3).
4. Orthogonal and probably the highest value for Mob apps specifically: make
   coordinate taps unnecessary. `MobFrameTracker` in `ios/MobRootView.swift`
   already reports frames for nodes carrying an `:id`; extending it to nodes
   carrying `on_tap` would let `tap_xy` resolve a point to a tap handle and call
   `mob_send_tap` directly — the same thing SwiftUI's `onTapGesture` does, with
   no private API at all. Deliberately not done here: another agent is working
   in `MobRootView.swift`.
5. Also for the simulator: adding `.accessibilityAddTraits(.isButton)` +
   `.accessibilityAction { tap() }` alongside the `.onTapGesture` in
   `MobRootView.swift` would make `accessibilityActivate` genuinely fire
   `on_tap`, fixing simulator coordinate taps for `Box`/`Row`/`Column`. Same
   file, same reason for deferring.

## Consequences

- Coordinate-driven taps on a physical iPhone are **not working** and are now
  reported as `{:error, :no_effect}` rather than `:ok`. `Mob.Test.tap/2` (by tag)
  is unaffected and remains the supported way to drive Mob screens.
- None of the above is verified on hardware from this change — it is a reading
  of the code plus the reported device behaviour. Step 1 is the instrumentation
  that would turn it into evidence.
