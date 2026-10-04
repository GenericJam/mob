# Press in / out props, and a held press agents can drive

- Date: 2026-10-03
- Status: accepted

## Context

Hold-to-talk (MOB-380) needs to know when a finger goes down on a node and
when it comes up. Mob had `on_tap` and `on_long_press`, both of which fire
once, at the end of a gesture, so Operator built its mic as an app-local
Compose `native_view` around `detectTapGestures(onPress = { tryAwaitRelease() })`.

Agents could not test any of it. On the Moto G 2021, `adb shell input swipe
x y x y 3000` and `input motionevent DOWN/UP` never reached Compose as a held
press, and `Mob.Test.long_press_xy/4` holds and releases inside one call, so
nothing can look at the app while the finger is down.

## Decision

1. **`on_press_in` / `on_press_out`**, named after React Native's
   `onPressIn` / `onPressOut` rather than `on_press` / `on_release`, because
   "press" alone reads as a tap in mob's existing vocabulary. Messages are
   `{:press_in, tag}` / `{:press_out, tag}`, with no payload: a handler that
   wants the hold length measures it on the BEAM, where both events cross the
   same channel. Discrete native input (`Mob.Event.NativeInput`).

2. **They observe without consuming, on every node type**, `button` included
   (unlike `on_long_press`, which follows iOS's `mobGestures` node set).
   Android: a `pointerInput` on the Initial pass that never consumes, ending
   when every pointer is up (Compose reports a cancel that way) or in a
   `finally` when the detector is torn down. iOS 18+: a UIKit recognizer
   (`UIGestureRecognizerRepresentable`) that never recognizes, recognizes
   simultaneously with everything and neither cancels nor delays touches, so
   the press ends in `touchesEnded` / `touchesCancelled`. A simultaneous
   `DragGesture(minimumDistance: 0)` was tried first and rejected: a swipe
   starting on the node no longer scrolled its ScrollView, and a quick tap
   delivered `tap` before `press_in`. iOS 17 falls back to that DragGesture
   behind a `@GestureState` (resets on cancel), accepting both flaws.

3. **Always paired, so routing is snapshotted at touch-down.** A press almost
   always causes a re-render ("listening"), and `set_root` commits the new
   handle generation on the BEAM thread before the UI thread has the new
   tree. A press_out looked up from its handle at lift time can therefore be
   rejected as stale, and the app is left believing the finger is still
   down. So at touch-down native resolves both handles identity-tolerantly
   (same slot, pid and tag, like change events), copies press_out's pid and
   tag into a slot of its own, and only then sends press_in; at the lift it
   sends press_out from that copy, once. If a declared handle can't be
   resolved, neither is sent. This is a deliberate exception to "plain taps
   and the other gestures stay generation-strict" (AGENTS.md pre-empt rule
   3): the pair is one gesture whose second half must survive renders.

   **A press node's tap is identity-tolerant too.** On the emulator, 1–6 of
   20 `tap_xy` taps on a box whose `on_press_in` changed its label were lost
   (logcat: "rejected stale event handle"): the tap's handle belonged to the
   tree before the press's render. For a node that declares `on_press_in` or
   `on_press_out`, the tap goes through `mob_send_press_tap`, which resolves
   like a change event: the slot still holds the same pid and tag, so the
   `{:tap, tag}` delivered is the message the tapped node declared. The
   bridge picks it: Android's `sendTapFor` in `RenderNodeInner` and
   `MobButton`, iOS's `on_tap` deserialiser.
   Plain taps keep the strict `mob_send_tap`: a first cut made every tap
   tolerant, and review found that a stale positional tag such as Mob.List's
   `{:select, id, index}` would then select whichever row the list had moved
   into that index, where the strict lookup drops it. The other gestures stay
   strict.

4. **A held press in `Mob.Test` (Android): `press_down_xy/4`,
   `press_move_xy/3`, `press_up_xy/3`, `hold_xy/4`.** The app's own
   `MobBridge` dispatches in-process `MotionEvent`s at the decor view, like the
   other synthetic gestures, but the finger stays down between calls. The
   bridge returns an int code, not a boolean, so `:already_pressed`,
   `:not_pressed` and `:window_gone` are distinguishable from
   `:dispatch_failed`. One held press at a time; the other synthetic
   gestures refuse while it is down, since their own DOWN would restart the
   gesture stream under it. `:max_hold_ms` (30 s default) cancels a press a
   crashed test never lifted.

5. **iOS gets by-tag driving only.** No in-process touch injection reaches
   SwiftUI (decisions/2026-08-09-tap-xy-reports-observed-effect.md), so the
   `_xy` NIFs return `{:error, :not_supported}`; `press_in/2`, `press_out/2`
   and `hold/3` send the messages on every platform, and a real touch comes
   from the simulator (mobile-mcp / agent-device).

## Consequences

- The Android half lives in the generated `MobBridge.kt` / `beam_jni.c`, so it
  needs `mob_new` 0.6.5 or newer; an older app ignores the props and its
  `capabilities/1` reports the press NIFs false.
- `decisions/2026-09-30-native-input-is-an-action.md` lists the discrete
  events; `:press_in` / `:press_out` join them.
- No `mob_dev` MCP surface exists to extend; agents reach these through
  `Mob.Test` over dist.
- Speech-to-text, the other half of hold-to-talk, is the `mob_speech` plugin,
  not core: privacy-gated capabilities live in plugins
  (plugin_extraction_plan.md, Waves 2 and 6).
