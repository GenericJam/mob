# Zig for the Android NIF bridge and the native build

- Date: 2026-05-09 (greenlit with the build-system migration; Android port shipped 2026-05-11)
- Status: accepted
- Recorded: 2026-10-24, retroactively. The rationale was spread across
  `build_system_migration.md` and conversation; this file makes it findable.

## Context

- Android's native layer was C: `android/jni/mob_nif.c` (~2,570 lines, 74 NIFs)
  and `mob_beam.c` (~540 lines). Native builds were bash `build.sh` templates
  calling `xcrun cc` / NDK clang, and the static-NIF tables were hand-edited
  `driver_tab_{ios,android}.c` files that were easy to let drift between platforms
  (`build_system_migration.md` → "Why").
- A NIF runs inside the VM. A segfault or memory corruption there is not a
  process crash a supervisor restarts — it kills the BEAM, which in Mob is the
  whole app. The NIF bridge is the one layer Mob's fault tolerance doesn't
  cover, so it deserves the most careful language we can get.
- The conventional answer is C: `erl_nif.h`, the OTP docs, the NDK samples and
  nearly every published NIF are C. AI agents propose C by default for that
  reason.

## Decision

- **Android NIF bridge and BEAM launcher are Zig.** `mob_nif.zig` and
  `mob_beam.zig`, over hand-declared FFI in `mob_erts.zig` (ERL_NIF surface)
  and `mob_zig.zig` (JNI, libc, liblog, dlfcn, pthreads). Ported incrementally
  and byte-for-byte; `mob_nif.c` deleted in `7f237e7`.
- **Static-NIF driver tables are Zig** (`driver_tab_android.zig`,
  `driver_tab_ios.zig`, introduced in `b361383`), replacing the hand-edited C
  tables (the `.c` files were deleted in `ab9ff59`). The
  iOS table is comptime-gated through `build_options` instead of `#ifdef`.
- **`build.zig` orchestrates the native build.** The mob_new templates replace
  the bash scripts: Zig and plain C (OTP glue, sqlite, plugin C NIFs) compile
  through Zig for every target. Apple clang / `swiftc` still build ObjC and
  Swift (Zig's bundled clang can't build Apple framework module maps), and NDK
  clang is still the Android link driver.
- **iOS stays Objective-C** (`ios/mob_nif.m`). UIKit/Cocoa APIs are ObjC and
  ARC manages memory; Zig there would mean wrapping the platform's own idiom.
- **Hand-declare the FFI; no `@cImport`.** During the port, Zig 0.17-dev had
  removed `@cImport` and `translate-c` hung on the NDK's `jni.h`. Both surfaces
  are small and stable (the JNI ABI is essentially unchanged since Java 1.1).
  libc declarations go through `mob_zig.zig` too
  (`decisions/2026-09-14-android-libc-decls-through-mob_zig.md`).

Why Zig over C, concretely:

- Types carry what C leaves implicit: optional pointers instead of implicit
  null, slices that know their length, error unions instead of ignorable return
  codes, `comptime` constraints (e.g. `erts.atom` requires a compile-time-known
  name).
- `defer` / `errdefer` put the release on the line right after the acquire,
  and it runs on every exit path. C NIF code releases at each `return`, and an
  early return added later is exactly where a leak or a held lock slips in —
  for humans, and even more for agents editing one branch of a long function.
  With `defer`, reviewing a resource means reading two adjacent lines, not
  tracing every return. Before the port, `mob_nif.c` released resources by hand
  (72 explicit `enif_free_env` / `enif_mutex_unlock` / `ReleaseStringUTFChars`
  calls).
- The C ABI is native — `callconv(.c)` exports and `extern fn` imports
  (`@extern` where the symbol name is chosen at comptime), no glue layer
  between Zig and libbeam/JNI.
- `comptime` replaces both the preprocessor and the code-generation step.

## Consequences

- **`defer` adoption is partial.** In `mob_nif.zig`, 40 of 45 `enif_free_env`
  calls are deferred, but only 7 of 22 `enif_mutex_unlock` and 2 of 6
  `releaseStringUTFChars` calls are; the rest still release by hand on each
  return, C-style. New code pairs every acquire with a `defer`; converting the
  remaining manual sites is open work.
- **Runtime safety checks are off in every build.** The mob_new templates
  hardcode `.ReleaseSmall`, which disables bounds and overflow checks, for dev
  deploys as well as releases. Zig's contribution here is the type-level
  discipline above, not runtime panics. Hunting a memory bug with checks on
  means editing the app's `build.zig` to `.ReleaseSafe`.
- **Zig is pre-1.0, and more than one pin is live.** The repo pins Zig in
  `.tool-versions`, but apps on an older mob_dev build with an older Zig, so the
  Android sources must compile on both (`ea6f06b`, #226). Treat a Zig bump like
  an OTP bump, and use only std APIs both pins have.
- **C-preprocessor aliases don't exist in Zig, and one target isn't all
  targets.** The port's first deploy, to an emulator, caught two bugs
  (`d5038c5`): `enif_make_int64` is a macro for `enif_make_long` on LP64, so
  the declaration compiled and then failed at `dlopen`; and a `@bitCast`
  between `jlong` (always 64-bit) and `ERL_NIF_TERM` (32-bit on armeabi-v7a)
  failed only when built for that ABI, which the earlier aarch64-only check
  never did. Check every hand-declared symbol against the header's `#define`s,
  build every ABI, and smoke-deploy after any port.
- **Core's `android/jni/` is Zig-only; don't add C there.** Plugin NIFs are a
  separate path: on Android they may be C (the manifest default) or Zig
  (`lang: :zig`, mob_dev `decisions/2026-05-28-zig-plugin-nifs.md`); on iOS
  they're ObjC/C (mob_dev `decisions/2026-06-04-ios-plugin-c-nifs.md`).
- **Agents will propose going back to C.** Their training data defaults to C,
  and their Zig knowledge is thinner and often from older Zig versions. Don't
  relitigate without evidence beyond "C is more common". When unsure of Zig
  syntax for the pinned version, read the existing code in `android/jni/` or
  the Zig standard library source for that version rather than guessing.
