# App Store Static-Link Plan

Working document for the framework work to make `mix mob.release` produce
App Store-shippable `.ipa` files. Update the **Status** line at the top
and check off workstream items as work progresses.

**Status (2026-05-01):** Plan written, no code changes started. Next: Workstream 1.

---

## Goal

`mix mob.release --app-store` produces an `.ipa` that:

1. Passes Apple's automated App Store Connect validator (no `.so`/`.a`
   files in bundle, no private UIKit selectors, complete Info.plist)
2. Lands in TestFlight after `mix mob.publish`
3. Runs identically to a `mix mob.deploy --native` build from the user's POV

**Per-app overhead must stay at zero** — the user runs the same command
shape; the framework does the right thing under the hood.

## Strategy: two release modes, not a rewrite

- **Dev mode (default)**: dynamic OTP runtime, full test harness,
  hot-reload-friendly. **Unchanged.** This is what `mix mob.deploy
  --native` and the existing `mix mob.release` produce.
- **App Store mode (opt-in via `--app-store`)**: statically linked
  `libbeam.a`, no `.so`/`.a` in bundle, test harness compiled out
  via `#if !MOB_APP_STORE`. This is the new path.

Justification: dev mode preserves what makes Mob *Mob* (sub-100ms
hot-push iteration, full agent test harness). App Store mode is a
narrower build for a single purpose. They can coexist; users opt in
when shipping.

## Confirmed decisions (2026-05-01)

1. **Two-mode strategy** — dev mode unchanged, App Store mode opt-in. ✓
2. **air_cart_max is the test case** — ship it through TestFlight as
   the proof point, then docs reflect a real working flow. ✓
3. **Scope discipline** — if exqlite cross-build hits a real wall
   (e.g. needs upstream patches to elixir_make), escalate before
   sinking another half day. ✓
4. **No new Mob features** during this work. Framework-plumbing for
   App Store only. ✓

## Prior art and existing artifacts

- **`~/code/beam-ios-test/BEAM-IOS.md`** — the proven recipe. Boots
  BEAM on iOS via static link in 64ms (M4 Pro sim) / ~120-180ms
  estimated A18 device. Read this before workstream 4.
- **Pre-built static archives** (`/Users/kevin/code/otp/bin/`):
  - `aarch64-apple-ios/libbeam.a` (4.2 MB)
  - `aarch64-apple-iossimulator/libbeam.a`
  - `liberts_internal_r.a`, `libethread.a`, `libei.a`, `libei_st.a`
  - `libzstd.a`, `libepcre.a`, `libryu.a`
  - `asn1rt_nif.a`
- **OTP build flag**: `RELEASE_LIBBEAM=yes` is what produced the above
  during the original `~/code/otp` cross-build.

## Workstreams

### Workstream 1 — Cross-build infrastructure (~half day)

**Goal**: every NIF an app uses has a static `.a` for both iOS targets,
cached and deterministically rebuildable.

- [ ] Solve exqlite first (only third-party NIF in air_cart_max)
- [ ] `mix mob.cross_build_nif <hex_package>` task
  - [ ] Resolve build script (Makefile / cmake / elixir_make / rebar3)
  - [ ] Cross-compile for `aarch64-apple-ios` and `aarch64-apple-iossimulator`
        via env-var hijacking (`CC`, `CFLAGS`, `SDKROOT`, `-mios-version-min`)
  - [ ] Coerce to `.a` output (most NIFs default to `.so`)
  - [ ] Cache in `~/.mob/cache/static-nifs/<package>-<version>/<target>/`
- [ ] Verify exqlite output: `nm sqlite3_nif.a` shows expected symbols
- [ ] Document the pattern; accept other NIFs may need per-package patches

**Risk**: NIF build systems are bespoke. Time-box exqlite to half a
day. If blocker, fall back: investigate whether system SQLite
(`/usr/lib/libsqlite3.dylib`, available on iOS) can replace exqlite
for shipped builds.

### Workstream 2 — Test-harness compile-out (~2 hours)

**Goal**: zero references to private UIKit selectors in App Store builds.

- [ ] Define `MOB_APP_STORE` flag (separate from existing `MOB_RELEASE`)
- [ ] Wrap test-harness NIFs in `mob/ios/mob_nif.m` with `#if !MOB_APP_STORE`:
  - [ ] `tap_xy`, `swipe_xy`, `tap_by_label`
  - [ ] `type_text`, `delete_backward`, `key_press`, `clear_text`
  - [ ] `long_press_xy`
  - [ ] `ax_action_at_xy`
- [ ] Mirror to `mob/android/jni/mob_nif.c` for symmetry
- [ ] Erlang stubs in `mob_nif.erl` stay (they `nif_error` at runtime
      in App Store builds — correct behavior)
- [ ] Verify: `nm <main_binary> | grep _addTouch` returns zero hits
- [ ] Verify: `nm <main_binary> | grep _setHIDEvent` returns zero hits

Doing this first proves the `MOB_APP_STORE` flag plumbing works
before the bigger restructure in workstream 4.

### Workstream 3 — Info.plist + IPA packaging fixes (~1 hour)

**Goal**: the small Apple-error categories (3 of 4) cleared.

- [ ] Synthesize `MinimumOSVersion` and `DTPlatformName` at build time
      in `mix mob.release` (always match `IPHONEOS_DEPLOYMENT_TARGET`
      and SDK in use)
- [ ] Update `mob_new` template's Info.plist scaffold to include them
- [ ] Switch `mob.release` IPA packaging from `zip -r` to
      `ditto -c -k --keepParent --sequesterRsrc` (preserves the
      `_CodeSignature/CodeResources` symlink)
- [ ] Verify: `unzip -l <ipa> | grep CodeResources` shows two entries,
      one of them a symlink

### Workstream 4 — Static-link release pipeline (~half day)

**Goal**: the heart of the change. App Store mode emits a single Mach-O
binary with everything statically linked, bundles only `.beam` files.

- [ ] New build script: `ios/release_app_store.sh` (generated alongside
      the existing `release_device.sh` when `--app-store` passed)
- [ ] Single `clang` link invocation taking:
  - [ ] All app `.o` files (mob_nif.m, mob_beam.m, app-specific Swift)
  - [ ] `libbeam.a` + companions from `~/code/otp/bin/aarch64-apple-ios/`
  - [ ] All cached static NIF archives from workstream 1
  - [ ] Standard frameworks (UIKit, SwiftUI, AVFoundation, etc.)
- [ ] Bundle ONLY `.beam` files (compiled app + Elixir stdlib).
      Keep `releases/<n>/start.boot` (non-executable boot script).
- [ ] Strip from bundle: all `.so`, all `.a`, all standalone executables
      under `otp/lib/*/priv/bin/` and `otp/lib/*/priv/lib/`
- [ ] Verify: `find <App>.app -name '*.so' -o -name '*.a' -o -type f -perm +111 ! -name '<App>'`
      returns empty
- [ ] Verify: `du -sh <App>.app` should be smaller than current
      (~64 MB → expected ~15-20 MB)

### Workstream 5 — End-to-end loop (~half day)

**Goal**: a real TestFlight build from air_cart_max.

- [ ] `mix mob.release --app-store` from air_cart_max
- [ ] `mix mob.publish`
- [ ] Apple validator runs (~60s); fix → repeat
- [ ] Build appears in App Store Connect → TestFlight tab
- [ ] Add internal tester, install via TestFlight app on iPhone
- [ ] Confirm app boots, themes work, calculator math is correct,
      mailto link launches, settings persistence works

Plan for 4-6 round trips with Apple's validator. Each cycle is
cheap (~60s upload + ~60s validation).

### Workstream 6 — Test coverage + docs update (~half day)

**Goal**: this doesn't regress; users find current docs.

- [ ] Tests for `mix mob.release --app-store`:
  - [ ] Generated link command shape (right archives, right flags)
  - [ ] Bundled `.app` contents (no `.so`/`.a`/standalone bins)
  - [ ] Info.plist key presence (MinimumOSVersion, DTPlatformName)
- [ ] Tests for `mix mob.cross_build_nif`:
  - [ ] Idempotent caching
  - [ ] Error on unknown build system
- [ ] Update `mob_dev/guides/publishing_to_testflight.md`:
  - [ ] Remove "Known limitation" section
  - [ ] Replace with the working happy path
- [ ] Update `mob/guides/publishing.md`: drop the limitation note
- [ ] Update `mob/future_developments.md`: move this entry to a "Done"
      section or delete it

## Open questions to revisit as work progresses

These are deliberately deferred until the relevant workstream surfaces them:

- **NIF build system coverage** — exqlite uses elixir_make. What about
  packages using rebar3 (most pure-Erlang NIFs), CMake, or bare
  Makefiles? Document patterns as we encounter them.
- **dSYM upload** — Apple wants symbol files for crash symbolication.
  `xcodebuild` already produces them; need to wire into `mob.publish`
  upload alongside the `.ipa`.
- **iOS simulator path** — App Store mode is primarily for device
  builds, but we want sim builds for testing too. The `iossimulator`
  static archives exist; just need to plumb a sim variant.
- **Bitcode** — Apple disabled the requirement in 2022. If they
  re-enable, need `-fembed-bitcode` in link flags. Out of scope until
  Apple does something.
- **What if the user's app uses a NIF we can't cross-build statically?**
  Need a clear error message at `mix mob.release --app-store` time
  pointing at the failed package and the workaround options.

## Risk register

| Risk | P | Impact | Mitigation |
|---|---|---|---|
| exqlite cross-build fails / has C++ runtime headaches | M | blocks workstream 1 | Time-box half day; fallback: investigate system `libsqlite3.dylib` |
| Other NIFs need bespoke per-package work | H (long-term) | future apps may bounce | Document the pattern in mob_dev; accept `--custom-script <path>` escape hatch |
| Apple validator finds new error categories after obvious 17 | M | adds round trips | Iteration is cheap; budget 4-6 cycles |
| Bitcode requirement re-enabled by Apple | L | needs `-fembed-bitcode` | Out of scope until Apple acts |
| dSYM upload required and not wired in | M | crash reports unsymbolicated | Already in xcodebuild output; just need altool integration |
| Static-linked NIFs break hot reload in dev mode | n/a | dev mode unchanged in this plan | App Store mode is a separate path; dev mode preserved |

## Decisions log

Capture non-obvious calls made *during* the work here, with date + reason.

- _(empty — populate as workstream 1 starts)_

## Total scope

2-3 days focused work, roughly:
- Day 1 AM: workstream 1
- Day 1 PM: workstreams 2 + 3
- Day 2 AM: workstream 4
- Day 2 PM: workstream 5
- Day 3 AM: workstream 6

End state: Mob ships to App Store. air_cart_max is the proof. The
"Known limitation" sections in both guides get retired.
