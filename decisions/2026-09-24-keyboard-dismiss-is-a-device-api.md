# Keyboard dismissal is a device API (`Mob.Keyboard`)

- Date: 2026-09-24 (revised 2026-10-23)
- Status: accepted

## Context

A downstream app put a weight field on a `keyboard: "decimal"` pad and wanted
its own Done pill, and a tap on blank space, to close the keyboard. The
decimal pad has no return key, so `on_submit` never fires; the built-in exits
are another field taking focus, the field leaving the tree, and the "Done"
`MobTextField` adds to the iOS keyboard toolbar. That toolbar does render in
a bare `MobHostingController` root (checked on the iOS 26.5 simulator). What
was missing is the app-initiated case: nothing let a handler take the
keyboard down.

## Decision

- **A device API, not a harness NIF.** A screen calling `dismiss_keyboard/0`
  is *acting*, not reporting on the app, so the observed-effect rule
  (`2026-08-09-tap-xy-reports-observed-effect.md`) doesn't apply and there is
  no effect to report back; `key_press(:escape)` remains the observing form
  for a test. `Mob.Keyboard.dismiss/1` ignores the NIF's result and returns
  the socket.
- **Resign whatever is first responder** in any visible window of a connected
  scene, the walk `delete_backward` / `key_press` use. Nothing focused is not
  an error.
- **iOS waits for the resign (IO_BOUND, 2 s bound).** It was first
  `dispatch_async` and returned at once, like `haptic/1`. The dismissing
  handler usually re-renders too, and `MobTextField` adopts a new `value:`
  only once it is no longer focused (a focused field keeps what the user is
  typing). With the async resign, that render reached a field SwiftUI still
  had focused: on the iPhone Air simulator (iOS 27.0), after an edit, the
  value assigned next to the dismiss was dropped in nearly every run and the
  field kept showing the typed text. Returning only once the main thread has
  resigned queues the render behind it; the value then landed in 22 of 22
  runs. `{:error, :timeout}` if the main thread doesn't get to it in time.
- **Android hides the IME and clears focus.** `MobBridge.dismissKeyboard()`
  (mob_new) calls `InputMethodManager.hideSoftInputFromWindow` and
  `clearFocus()` on the focused view. Hiding alone left the Compose field
  focused, so no `on_blur` and no `on_focus` on the next tap, unlike iOS.
  Android doesn't wait: its field adopts a rendered value while focused
  (`MobTextSync`), and the value landed every run.
- **Optional on Android.** The bridge method is cached with `cacheOptional`;
  a bridge without it returns `{:error, :not_loaded}`, which `dismiss/1`
  swallows, so an app on an older generated bridge degrades to "keyboard
  stays up" rather than crashing.
- **Guarded on the host.** Unlike `Mob.Haptic`, `dismiss/1` checks `:mob_nif`
  is loaded before calling it: it sits in handlers `Mob.ScreenCase` drives on
  the host, where no NIF library loads, and a screen must stay testable there.
- **Android `on_blur` is identity-tolerant.** The dismissing handler's render
  commits the new tap table on the BEAM thread before Compose recomposes, so
  the blur that `clearFocus()` causes carries the previous render's handle.
  The generation-strict `mob_send_blur` dropped 6 of 8 such blurs on a Moto G
  Power 2021. It now resolves like change events and the iOS final-text blur
  (same slot, pid and tag), and all 10 arrived. iOS already delivered blur
  through `mob_send_text_final`, which is identity-tolerant (MOB-406), and
  needed no change.

## Consequences

- Cross-repo: `mob` (Elixir, iOS and Android NIFs) plus `mob_new` (the
  generated `MobBridge.dismissKeyboard`). Existing Android apps need the
  method copied into their `MobBridge.kt`.
- Verified on the iPhone Air simulator (iOS 27.0) and a Moto G Power 2021
  (Android 11) with a decimal field: the keyboard goes down, a `value:`
  assigned in the same handler reaches the field, `on_blur` arrives with and
  without a re-render, and the app keeps running. An Android build without
  the bridge method logs `dismissKeyboard not found (optional)` at NIF load,
  returns `{:error, :not_loaded}`, and leaves the keyboard up.
