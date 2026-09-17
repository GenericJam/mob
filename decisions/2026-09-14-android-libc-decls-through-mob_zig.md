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

Under zig `0.17.0-dev.269+ebff43698`, an `extern "c" fn` declaration whose
symbol name matches one of a handful of well-known libc entry points fails
the compilation unit with `dependency on libc must be explicitly specified
in the build command` unless the object's module is created with
`.link_libc = true`. `open`, `write`, and `close` are on that list; `fopen`,
`fread`, `fclose`, `mkdir`, `unlink`, `snprintf`, `read`, etc. — all
declared in `mob_zig.zig` as `pub extern fn` — are not, or are not detected
by the same check.

MOB-196 fixed this for newly-generated apps by adding `.link_libc = true`
to `addZigObject` in `mob_new`'s Android `build.zig.eex`. But every app
generated before mob_new 0.5.1 has an app-owned `build.zig` that omits the
flag. Pointing such an app at mob master or mob 0.8.x fails on
`mix mob.deploy --native --android` with an error at
`mob_nif.zig:4374` that says nothing about mob and offers no fix.

## Decision

Move the three declarations into `android/jni/mob_zig.zig` (aliased as `jni`
in `mob_nif.zig`) alongside the sibling libc bindings already there —
`pub extern fn`, no `"c"` calling-convention qualifier. `writeMarker` in
`mob_nif.zig` now calls `jni.open`, `jni.write`, `jni.close` and references
`jni.O_WRONLY | jni.O_CREAT | jni.O_TRUNC` for the flag constants (also
lifted into `mob_zig.zig`). The three `posix_open/write/close` inline
wrappers in `mob_nif.zig` are deleted.

The reason this works is the specific shape of zig 0.17's check: it is
triggered by `extern "c" fn <libc-name>` in a compilation-unit module that
was not created with `.link_libc = true`. A bare `extern fn` — the default
calling convention is C on host-target ABIs anyway — sidesteps it. The
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
  as `pub extern fn`, not into a per-caller `extern "c" fn` block. If a
  variadic C function is genuinely needed (where the `"c"` qualifier
  matters for calling convention), that is the exception — and it belongs
  in `mob_zig.zig` too, where the rest of the FFI surface is auditable in
  one file.
- `test/mob/android_libc_free_test.exs` guards the invariant by asserting
  `mob_nif.zig` declares no `extern "c" fn` and that the `writeMarker`
  path routes through `jni.*`. It is a source-scan test — CI does not run
  zig — but it catches the specific class of change that would reintroduce
  the break, and its failure message names the offending lines so an author
  who trips it sees the tradeoff before an old-style app breaks.
- `link_libc = true` in `mob_new`'s Android `build.zig.eex` (MOB-196) is
  now redundant — new apps do not need it either. Not removed here: it
  costs nothing, and if a future addition genuinely does need libc the
  flag lets the app keep building. If someone re-audits the template,
  drop it then.
- The runtime behavior of the post_mortem marker write is unchanged; the
  file at `<data>/mob_post_mortem_last_ts` is opened, written, and closed
  by the same three Bionic calls as before.
