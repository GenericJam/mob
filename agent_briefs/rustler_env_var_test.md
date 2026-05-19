# Agent brief: test the env-var approach for rustler's Bionic dlsym fix

## Goal

Implement and test the env-var-based approach for resolving `enif_*`
symbols on Android Bionic, as proposed by filmor (rustler maintainer)
in PR https://github.com/rusterlium/rustler/pull/726.

Success means we have a deployable end-to-end demonstration that the
proposed mechanism works in Mob's static-link deployment model. Report
the result back so we can push it as the new PR commit.

## Background — read first

You need to understand three things before touching code.

1. **The bug.** On Android Bionic (any version), `dlopen(NULL)` returns
   the app process's link namespace, which does NOT include symbols
   statically linked into a sibling `.so` even when that `.so` was
   loaded via `System.loadLibrary(..., RTLD_NOW | RTLD_GLOBAL)`. This
   is by-design Android linker behavior — they made the call for
   compat reasons in M and never reverted. See
   https://github.com/android/ndk/issues/201 for the canonical
   explanation by the Android linker maintainer (`dimitry-`).

2. **Why rustler hits this.** Rustler's runtime initialization uses
   `nif_filler` which does `dlopen(NULL)` + `dlsym(handle, "enif_*")`
   to populate its callback table. On Bionic that returns `NULL`
   for symbols statically linked into Mob's `libpigeon.so`, so
   rustler-based NIFs fail at runtime on Android.

3. **The current PR's approach (what we're replacing).** Uses
   `dladdr` on a known-in-rustler symbol to identify the `.so` that
   contains rustler, then `dlopen(self_path, RTLD_NOW | RTLD_NOLOAD)`
   to get an explicit handle to that `.so`. Works for Mob's
   static-link-everything model. Filmor's concern: hard-codes the
   assumption that `enif_*` is in the same `.so` as rustler. Won't
   generalize to setups with a separately-linked BEAM.

## The deal filmor offered

He proposed: **Mob sets an env var containing the path of the `.so`
that contains the `enif_*` symbols. Rustler's `DlsymNifFiller` reads
that env var and uses it directly. Existing `dladdr` logic stays as
the fallback for setups that don't set the env var.**

We own the Mob side (setting the env var). He owns the rustler side
(extending `DlsymNifFiller`).

Read the full PR conversation for context:
https://github.com/rusterlium/rustler/pull/726

## What to build and test

### Part A — Mob side: discover path + set env var

Goal: by the time rustler's NIF init runs, the env var (we'll call it
`RUSTLER_NIF_LIB_PATH`) holds the absolute path of `libpigeon.so`.

**Files to inspect first:**

- `/Users/kevin/code/mob/android/app/src/main/java/com/example/<app>/BeamForegroundService.kt`
  — where `System.loadLibrary("pigeon")` is called. The `.so` is
  fully loaded by the time this returns.
- `/Users/kevin/code/mob/android/jni/mob_beam.zig` (or `mob_beam.c`
  in older copies) — the C/Zig BEAM launcher. Already calls
  `setenv()` for `MOB_BUNDLE_OTP`, `MOB_DIST_PORT`,
  `MOB_NODE_SUFFIX`. The new env var goes here too.
- `/Users/kevin/code/mob/android/jni/mob_beam.h` — declarations
  for the launcher API.

**On the Kotlin side, the path resolves to:**

```kotlin
val nifLibPath = "${applicationInfo.nativeLibraryDir}/libpigeon.so"
```

Verify this path exists on a real device before relying on it. The
nativeLibraryDir is typically:
- `/data/app/~~<hash>==/<package>-<hash>==/lib/arm64` for installed apps
- `/data/app/<package>-N/lib/arm64` on older Android

Either pass this path through JNI into the launcher, or set the env
var directly from Kotlin via `android.system.Os.setenv()` (available
since API 21; Mob's min-SDK is well above this).

The simplest implementation: set it from Kotlin *before* anything
NIF-related runs (which means before `Mob.Dist.ensure_started/1`
indirectly triggers the rustler NIF on_load).

```kotlin
android.system.Os.setenv("RUSTLER_NIF_LIB_PATH", nifLibPath, true)
```

Verify the env var is visible from C (or to BEAM) by adding a one-shot
`Log.i(...)` from the launcher reading `getenv("RUSTLER_NIF_LIB_PATH")`.

### Part B — Rustler fork: read the env var in DlsymNifFiller

Goal: the existing `GenericJam/rustler:genericjam-android-rtld-default`
fork's `DlsymNifFiller` reads `RUSTLER_NIF_LIB_PATH` first; if unset,
falls back to current `dladdr` logic.

**Locate `DlsymNifFiller` in the fork:**

```bash
cd /Users/kevin/code/rustler  # or wherever the fork is checked out
grep -rn 'DlsymNifFiller\|dladdr\|nif_filler' rustler_sys/ rustler/ 2>&1 | head
```

The change is roughly:

```rust
// Before (current PR approach):
//   resolve self_path via dladdr, then dlopen(self_path, RTLD_NOW | RTLD_NOLOAD)
//
// After (env-var approach):
let handle = match std::env::var("RUSTLER_NIF_LIB_PATH") {
    Ok(path) if !path.is_empty() => {
        // Caller (Mob, etc.) explicitly told us where enif_* lives.
        let c_path = std::ffi::CString::new(path)?;
        unsafe { libc::dlopen(c_path.as_ptr(), libc::RTLD_NOW | libc::RTLD_NOLOAD) }
    }
    _ => {
        // Fall back to dladdr-based self-resolution for setups that
        // don't set the env var (most pre-existing rustler users).
        existing_dladdr_logic()
    }
};
```

Preserve the existing `dladdr` path as the else-branch. Backwards
compatibility is the point — current users keep working without
setting the env var.

Update the fork's commit and push to the `genericjam-android-rtld-default`
branch (or a new branch — your call).

### Part C — End-to-end test on a physical Android device

Goal: prove the chain works. A Mob app with a rustler-based NIF loads
on a real Bionic device and resolves `enif_*` symbols.

**Test app to use:** the existing `/Users/kevin/code/nif_race` project
already has a Rust NIF demo. Should work as the test harness.

**Procedure:**

1. Patch `nif_race/mix.exs` to point at the local rustler fork:
   ```elixir
   {:rustler, path: "/Users/kevin/code/rustler", override: true}
   ```
2. `mix mob.deploy --native --device <physical-android-serial>`
3. Watch logcat:
   ```bash
   adb -s <serial> logcat | grep -E 'rustler|MobBeam|nif_filler|RUSTLER_NIF_LIB_PATH'
   ```
4. Expected log lines:
   - `RUSTLER_NIF_LIB_PATH=/data/app/.../libpigeon.so` (from your debug log)
   - rustler successfully loading without dlsym failures
   - The nif_race app reaching its main screen
5. Hit the test button in the nif_race UI; verify the Rust NIF runs.

**If anything fails:**
- `adb shell ls /data/app/<package>/lib/arm64/libpigeon.so` to confirm the path exists
- Check `getenv("RUSTLER_NIF_LIB_PATH")` from C is non-NULL by adding a `__android_log_print` call in mob_beam
- `nm -D libpigeon.so | grep enif_` to confirm `enif_*` symbols are exported

### Part D — Report results

Document the result back in this brief or a follow-up file:

- Confirmation that the env-var approach works (or doesn't)
- The exact path nativeLibraryDir resolved to on the test device
  (paste-able evidence)
- Any deviations from the proposed approach (different env var name,
  different code path, etc.)
- A draft PR description for the rustler PR rewrite, in
  hand-written-by-Kevin style. Short and direct. No AI prose.
- A draft of the matching Mob-side commit message

If it doesn't work: document specifically *why* — failure logs,
symbol resolution output, anything that distinguishes "env var
mechanism is wrong" from "implementation detail is wrong."

## Constraints

- **Do not push the rustler-fork changes to upstream rusterlium/rustler.**
  Push to the user's own fork only. The PR description rewrite happens
  later, after Kevin has reviewed the test results.
- **Do not respond to filmor or modify the existing PR.** That is
  Kevin's interaction surface. Report back; Kevin handles the
  upstream conversation.
- **Don't write the actual response prose for filmor.** filmor has
  explicitly objected to AI-generated PR comments. You can sketch
  technical content. Kevin will hand-write the actual response.
- **Stick to the proposed approach.** Don't expand scope to the
  combined-staticlib refactor or any other alternative — that's a
  separate decision Kevin will make once this test is done.

## Success criteria

- [ ] `applicationInfo.nativeLibraryDir` confirmed to resolve to a
  real existing path on at least one physical Android device.
- [ ] `RUSTLER_NIF_LIB_PATH` env var set before rustler's NIF
  initialization runs.
- [ ] Rustler fork's `DlsymNifFiller` patched to read the env var;
  `dladdr` fallback preserved.
- [ ] nif_race (or equivalent rustler-using Mob app) deploys to a
  physical Android device and the Rust NIF resolves + executes
  successfully.
- [ ] Logcat evidence captured showing the env var being read and
  symbol resolution succeeding.
- [ ] Test summary documented for Kevin to use when updating the
  PR.

## Out of scope

- Combined staticlib pattern (filmor's preferred long-term approach)
- iOS-side anything (this bug is Android-Bionic-specific)
- Mob_dev plumbing changes beyond what's needed for the env var
- Documentation updates to mob/common_fixes.md or guides/
  (Kevin will land those separately if the approach works)
