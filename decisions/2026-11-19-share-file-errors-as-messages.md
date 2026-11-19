# Share-file errors arrive as messages; Android `shareFile` is optional and marshalled as UTF-16

- Date: 2026-11-19
- Status: accepted

## Context

`Mob.Share.text/2` is fire-and-forget and returns the `Mob.Socket` unchanged.
Adding `Mob.Share.file/3` introduces setup failure modes that `text/2` didn't
have: missing or unreadable files, paths outside Android's `FileProvider` roots,
absent foreground activity/scene, missing target apps on Android, and older
`mob_new` host templates that lack `MobBridge.shareFile`. Meanwhile, UI
presentation on both platforms happens asynchronously on the main/UI thread.

## Decision

- **Socket-threaded fire-and-forget with failure messages.** `Mob.Share.file/3`
  always returns the socket unchanged so callers chain it in callbacks like
  `text/2` and `Mob.Keyboard.dismiss/1`. Setup errors go to `self()` as
  `{:mob_share, :error, reason}` (`:not_found | :no_activity | :no_app | :failed | :unsupported`),
  either synchronously from the NIF/Elixir check or asynchronously from the main
  thread. Success and share-sheet completion or cancellation are never reported,
  because neither platform guarantees a reliable completion signal across share
  targets and fire-and-forget callers don't track request IDs.
- **Optional Android bridge lookup (`cacheOptional`).** Caching
  `MobBridge.shareFile` with `cacheRequired` would fail `nif_load` and crash at
  boot on every app generated before `mob_new` added `shareFile`. Caching it
  with `cacheOptional` lets older hosts boot normally and report
  `{:error, :unsupported}` at call time when `Bridge.share_file` is null.
- **UTF-16 marshalling via JNI `NewString`.** `mob_nif.zig`'s other string NIFs
  use `newStringUTF`, which expects JNI *modified* UTF-8 and corrupts
  supplementary-plane characters such as emoji in file paths or titles.
  `nif_share_file` converts UTF-8 binaries to UTF-16LE with `enif_alloc`/`enif_free`
  (no fixed stack cap and no libc dependency) and passes them via JNI `NewString`,
  clearing any pending Java exceptions after `NewString` and `CallStaticVoidMethod`.

## Consequences

- Callers that want to surface share-sheet setup failures (such as exporting a
  file outside Android's cache directory) match `{:mob_share, :error, reason}`
  in `handle_info/2`; callers that ignore failures keep working unchanged.
- Existing `mob_new` apps must port `MobBridge.shareFile` before `Mob.Share.file/3`
  works on Android, and must place shared files under a `FileProvider` root
  (`Mob.Storage.dir(:cache)` in generated apps).
