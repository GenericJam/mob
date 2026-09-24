# Keyboard dismissal is a fire-and-forget device API (`Mob.Keyboard`)

- Date: 2026-09-24
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

- **A device API, not a harness NIF.** `dismiss_keyboard/0` is shaped like
  `haptic/1` and `torch/1`: `dispatch_async` to the main thread, `ok` means
  queued. The observed-effect rule
  (`2026-08-09-tap-xy-reports-observed-effect.md`) governs harness NIFs that
  *report* on the app; a screen calling this is *acting*, and the observing
  form already exists — `key_press(:escape)` — for a test that needs to know.
- **Resign whatever is first responder** in any visible window of a connected
  scene, the walk `delete_backward` / `key_press` use. Nothing focused is not
  an error.
- **Optional on Android.** The bridge method is cached with `cacheOptional`;
  a bridge without it returns `{:error, :not_loaded}`, which
  `Mob.Keyboard.dismiss/1` swallows, so an app on an older generated bridge
  degrades to "keyboard stays up" rather than crashing. The Kotlin half
  (`MobBridge.dismissKeyboard()`, `InputMethodManager.hideSoftInputFromWindow`)
  is the paired `mob_new` change.
- **Guarded on the host.** Unlike `Mob.Haptic`, `dismiss/1` checks the stub is
  loaded before calling it: it sits in handlers `Mob.ScreenCase` drives on the
  host, where no NIF library loads, and a screen must stay testable there.

## Consequences

- Cross-repo, one issue: `mob` (Elixir + NIF + iOS + zig) plus `mob_new` (the
  generated `MobBridge.dismissKeyboard`). Until the template lands, Android is
  a documented no-op.
- Verified on the iOS 26.5 simulator over dist: `Mob.Test.type_text/2`
  succeeded before the call and returned `{:error, :no_first_responder}` after
  it, with the field still in the tree; full-screen captures agree. Android:
  host tests only (no Android toolchain on the authoring machine).
- Dismiss and a re-render in the same handler are safe for the field's
  value: the `value:` assigned alongside the dismiss reached the field
  (SwiftUI's focus state had already flipped when `MobTextField`'s
  `initialText` sync ran). The field's `on_blur` did **not** arrive in that
  case, while it did when the NIF ran with no re-render and via
  `key_press(:escape)` — consistent with the blur firing after the new render
  generation committed and being dropped as stale. Documented as "act in the
  dismissing handler, not in `on_blur`"; routing the resign through
  `Mob.Sender` so the blur lands in the new generation is the follow-up if
  that ever matters.
