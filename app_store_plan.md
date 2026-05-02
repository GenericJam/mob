# App Store Static-Link Plan

Working document for the framework work to make `mix mob.release` produce
App Store-shippable `.ipa` files. Update the **Status** line at the top
and check off workstream items as work progresses.

**Status (2026-05-02):** **UPLOAD SUCCEEDED**. Workstreams 1-5 done in ~3 hours (vs 2-3 day estimate). Build accepted by App Store Connect — Delivery UUID `6a1711f4-2f11-4023-9711-9ddcef583a73`. Awaiting Apple processing (~5-15 min) before it appears in TestFlight. W6 (test coverage + docs) still pending.

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

### Workstream 1 — Cross-build infrastructure (~~half day~~ COLLAPSED)

- [x] Solve exqlite first — **already done by the existing pipeline**
- [x] Static archive at `~/.mob/cache/otp-ios-device-*/lib/exqlite-*/priv/sqlite3_nif.a`
      (1.5 MB, valid arm64, `_sqlite3_nif_nif_init` symbol present)
- [x] All other static archives present too: `libbeam.a`, `liberts_internal_r.a`,
      `libethread.a`, `libei.a`, `libei_st.a`, `libzstd.a`, `libepcre.a`,
      `libryu.a`, `asn1rt_nif.a`
- [x] Existing `release_device.sh` already links them all into the main
      binary correctly (lines 41-49 + 251-269 of the generated script)

**The bug isn't missing infrastructure.** It's that the same files that
get linked into the binary ALSO get bundled into `$APP/otp/lib/` via
`rsync -a --delete $OTP_ROOT/lib/ $OTP_BUNDLE/lib/` (line 297). Apple
rejects the bundled `.a`/`.so`. The fix is in workstream 4 (strip
unused libs + binaries from the bundle BEFORE packaging the IPA), not
in build infrastructure.

This collapses scope significantly. Workstream 4 is now the only
non-trivial piece; everything else is small fixes.

### Workstream 2 — Test-harness compile-out (~2 hours)

**Goal**: zero references to private UIKit selectors in App Store builds.

**Scope decision (2026-05-01)**: dropped the planned separate
`MOB_APP_STORE` flag — `MOB_RELEASE` is only set by the release
script, dev mode never sets it, so reusing it for test-harness gating
is correct. There's no use case for "release build with test harness"
or "dev build without test harness".

- [x] Wrap test-harness section in `mob/ios/mob_nif.m` with `#if !MOB_RELEASE`
      (block from `nsstring_to_term` helpers through end of `nif_swipe_xy`)
- [x] Wrap the test-harness entries in the `nif_funcs[]` table with
      `#if !MOB_RELEASE`
- [x] **Add `-DMOB_RELEASE` to mob_nif.m's compile command** in
      `mob_dev/lib/mob_dev/release.ex` (was only being defined for
      mob_beam.m — discovered when first verification still showed
      private selectors in the binary)
- [x] Verify dev path still builds (`mix mob.deploy --native` — test
      harness present, app boots)
- [x] Verify release path strips selectors:
      `strings AirCartMax | grep -cE "^_addTouch|^_setHIDEvent|..."` = 0
- [x] Verify release path strips test-harness symbols:
      `nm AirCartMax | grep -cE "nif_tap_xy|nif_swipe_xy|..."` = 0
- [ ] Mirror to `mob/android/jni/mob_nif.c` for symmetry (lower priority
      — Android doesn't have the same review gate; defer to W6)

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

- [x] `mix mob.release` from air_cart_max
- [x] `mix mob.publish` — **UPLOAD SUCCEEDED 2026-05-02 00:03**
      (Delivery UUID `6a1711f4-2f11-4023-9711-9ddcef583a73`)
- [x] Apple validator round trips: 4 cycles total
  - Round 1: 17 errors (.so/.a + selectors + Info.plist + symlink)
  - Round 2: down to 1 error (UIDeviceFamily missing)
  - Round 3: 1 different error (DT* keys missing for SDK validation)
  - Round 4: DTXcode encoding bug (5 digits, should be 4)
  - Round 5: ✅ accepted
- [ ] Build appears in App Store Connect → TestFlight tab (Apple
      processing ~5-15 min)
- [ ] Add internal tester, install via TestFlight app on iPhone
- [ ] Confirm app boots, themes work, calculator math correct,
      mailto link launches, settings persistence works

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

- **2026-05-01 — Workstream 1 collapsed.** Recon found that
  `~/.mob/cache/otp-ios-device-*/lib/exqlite-*/priv/sqlite3_nif.a` is
  already produced by the existing build pipeline (1.5 MB, valid
  arm64). All other static archives (`libbeam.a`, `liberts_internal_r.a`,
  `libethread.a`, `libei.a`, `libei_st.a`, `libzstd.a`, `libepcre.a`,
  `libryu.a`, `asn1rt_nif.a`) likewise present. The release script's
  link line already pulls them all in. The bug is that the same files
  that get linked into the binary ALSO get bundled into `$APP/otp/lib/`
  via wholesale `rsync` — Apple rejects the bundled copies. Fix moves
  to workstream 4 (strip-from-bundle), no cross-build infra needed.
- **2026-05-01 — Dropped `MOB_APP_STORE` flag.** Plan called for a new
  flag separate from `MOB_RELEASE`, but `MOB_RELEASE` is only set by
  the release script; dev mode never sets it. Reusing the existing flag
  for test-harness gating is correct — there's no use case for "release
  build with test harness" or "dev build without test harness". One
  flag, one path.
- **2026-05-01 — Plan to modify existing `mix mob.release` rather than
  add `--app-store` opt-in flag.** The current `mix mob.release` task
  already documents itself as producing "App Store / TestFlight" builds.
  Modifying it to actually achieve that is more honest than a parallel
  task. Anyone using `mix mob.release` today is doing so because they
  want an App Store build; making it work doesn't break anyone.
- **2026-05-02 — Apple expects a full set of `DT*` keys in Info.plist.**
  Initial fix added only `MinimumOSVersion` + `DTPlatformName` (per the
  observed errors). After that cleared, validator surfaced "Unsupported
  SDK or Xcode version" (90534) — turns out the validator
  cross-references `DTSDKBuild` + `DTXcodeBuild` against an allow-list
  of accepted Xcode releases. Fix: emit the full standard set
  (`DTSDKName`, `DTSDKBuild`, `DTPlatformVersion`, `DTPlatformBuild`,
  `DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`)
  derived from `xcrun --show-sdk-version`/`-build-version` and
  `xcodebuild -version`.
- **2026-05-02 — `DTXcode` encoding is `MAJOR×100 + MINOR×10 + PATCH`,
  not `MAJOR×1000 + …`.** First attempt produced "26040" (5 digits)
  instead of "2640" (4 digits). Apple's historical encoding has always
  been 4 digits because Xcode major was 2-digit through Xcode 16; the
  pattern continued for Xcode 26.

## Total scope

2-3 days focused work, roughly:
- Day 1 AM: workstream 1
- Day 1 PM: workstreams 2 + 3
- Day 2 AM: workstream 4
- Day 2 PM: workstream 5
- Day 3 AM: workstream 6

End state: Mob ships to App Store. air_cart_max is the proof. The
"Known limitation" sections in both guides get retired.
