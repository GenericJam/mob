# Android libc decls go through mob_zig, not `extern "c" fn` in-place

- Date: 2026-09-14
- Status: accepted
- Issue: MOB-226 (regression from MOB-180)

## Context

MOB-180 (mob #156, 2026-09-11) landed the post_mortem marker write path in
`android/jni/mob_nif.zig`, and to write ~24 bytes at boot without pulling in
`std.fs`, it declared the three libc calls it needed directly:

```zig
extern "c" fn open(...) c_int;
extern "c" fn write(...) isize;
extern "c" fn close(...) c_int;
```

Under zig `0.17.0-dev.269+ebff43698`, `extern "c"` is a *library* annotation
(link against library `c`), not a calling-convention qualifier. Sema rejects
any extern declaration whose library name is libc with `dependency on libc
must be explicitly specified in the build command` unless the module is
created with `.link_libc = true` (see `src/Sema.zig` L8444-8465 at
`ebff43698`). The check is on the library name, not the symbol name: the
bare `pub extern fn` declarations in `mob_zig.zig` (`fopen`, `read`,
`snprintf`, `__android_log_print`, ...) carry no library and pass.

MOB-196 fixed this for newly-generated apps by adding `.link_libc = true`
to `addZigObject` in `mob_new`'s Android `build.zig.eex`. But every app
generated before mob_new 0.5.1 has an app-owned `build.zig` that omits the
flag. Pointing such an app at mob master or mob 0.8.x fails on
`mix mob.deploy --native --android` with an error at
`mob_nif.zig:4374` that says nothing about mob and offers no fix.

## Decision

Move the three declarations into `android/jni/mob_zig.zig` (aliased as `jni`
in `mob_nif.zig`) alongside the sibling libc bindings already there —
bare `pub extern fn`, no `"c"` library annotation. `writeMarker` in
`mob_nif.zig` now calls `jni.open`, `jni.write`, `jni.close` and references
`jni.O_WRONLY | jni.O_CREAT | jni.O_TRUNC` for the flag constants (also
lifted into `mob_zig.zig`). The three `posix_open/write/close` inline
wrappers in `mob_nif.zig` are deleted.

The reason this works: zig's check fires on the `"c"` library annotation in
a module not created with `.link_libc = true`. A bare `extern fn` names no
library — the default calling convention is the target's C ABI either way —
so it sidesteps the check. The
object semantics are identical: both forms emit an unresolved external
symbol whose calling convention is whatever the target's C ABI is, and
Bionic's `libc.so` provides the definition at APK-load time. The APK's
shared library links against `libc.so` from the NDK sysroot regardless of
whether zig was told about libc at compile time.

The other two options in the ticket — a `mob_dev` preflight that detects
the missing `link_libc` and warns; or `mix mob.deploy` regenerating the
app-owned `build.zig` from the template — are both still worth having as
follow-ups (the drift between the app-owned build.zig and the template is
recurring). But they widen the fix; the compile-time change here is the
narrowest way to unbreak every existing app.

## Consequences

- New libc symbols added for use from mob's Zig code go into `mob_zig.zig`
  as bare `pub extern fn`, never `extern "c" fn` — including variadic
  functions (`snprintf` and `__android_log_print` are already declared bare
  with `...`; the `"c"` annotation is not needed for varargs).
- `test/mob/android_libc_free_test.exs` guards the invariant by running
  `zig build-obj` on `mob_nif.zig` for `aarch64-linux.24.0-android` with no
  libc — the same shape as a pre-0.5.1 app's build.zig — so any libc
  dependency reintroduced anywhere in the module fails it. It is tagged
  `:zig` and excluded when no `zig` is on PATH (CI has none), so it runs on
  developer machines that build Android.
- `link_libc = true` in `mob_new`'s Android `build.zig.eex` (MOB-196) is
  now redundant — new apps do not need it either. Not removed here: it
  costs nothing, and if a future addition genuinely does need libc the
  flag lets the app keep building. If someone re-audits the template,
  drop it then.
- The runtime behavior of the post_mortem marker write is unchanged; the
  file at `<filesDir>/mob_post_mortem_appexit_marker.txt` is opened,
  written, and closed by the same three Bionic calls as before.
  (Corrected 2026-10-01: an earlier revision named it
  `<data>/mob_post_mortem_last_ts`, which is not the file's name; see
  `MARKER_FILENAME` in `android/jni/mob_nif.zig`.)
