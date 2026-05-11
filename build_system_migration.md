# Build System Migration Plan

> Multi-month refactor moving Mob's build pipeline to a layered architecture:
> Mix (developer CLI) → Igniter (Elixir-side scaffolding) → Zig build (native
> compile orchestration) → Xcode/Gradle (platform packaging). Touches all three
> repos. Sequenced to ship value at every checkpoint.

**Status:** Greenlit 2026-05-09. Begin after the in-flight `pythonx-support`
work merges to master in `mob_dev` and `mob_new`.

---

## Why

Today's build pipeline is shell scripts + hand-edited C tables + regex-patched
Phoenix generation. Three pain points that compound as the NIF surface grows:

1. **Adding a new static NIF requires touching `driver_tab_ios.c`,
   `driver_tab_android.c`, every `build.sh` template, and `mix.exs` deps by
   hand.** No single source of truth, easy to drift between platforms.
2. **Build complexity lives in shell.** Every per-platform conditional, every
   `xcrun` invocation, every NDK path translation is bash. We just spent days
   debugging the OTP 29 rebuild because shell-script options handling doesn't
   compose. With the agent-runtime / JS sandbox / Pythonx work coming, the
   options matrix multiplies; bash won't survive that.
3. **`mix mob.new --liveview`'s Phoenix patches are regex.** Already broke twice
   in the OTP 29 rebuild (`:re.import/1` and the Elixir version drift). The
   regex approach is structurally fragile — needs to be AST-aware.

The migration target solves all three with the right tool per layer:

```
┌──────────────────────────────────────────────────────────────┐
│  Mix         — developer-facing CLI (mix mob.deploy, etc.)   │
└──────────────────────────────────────────────────────────────┘
              │                                  │
              ▼                                  ▼
┌──────────────────────────┐    ┌────────────────────────────────┐
│  Igniter                 │    │  Native build orchestration    │
│  Elixir AST scaffolding  │    │  (Xcode / Gradle for packaging)│
└──────────────────────────┘    └────────────────────────────────┘
                                              │
                                              ▼
                                ┌────────────────────────────────┐
                                │  Zig build                     │
                                │  Cross-platform compile +      │
                                │  options matrix + caching      │
                                └────────────────────────────────┘
                                              │
                            ┌─────────────────┼─────────────────┐
                            ▼                 ▼                 ▼
                        ┌───────┐         ┌───────┐         ┌───────┐
                        │  zig  │         │ cargo │         │zig cc │
                        │       │         │       │         │  (C)  │
                        └───────┘         └───────┘         └───────┘
```

Each layer owns one concern. None tries to do another's job.

---

## Repos affected

| Repo      | Weight     | Why                                                        |
|-----------|------------|-------------------------------------------------------------|
| `mob`     | Light      | Driver_tab generalizes; Android C → Zig in Phase 6        |
| `mob_dev` | Heavy      | Owns most Mix tasks + release scripts                      |
| `mob_new` | Heaviest   | Owns build.sh templates + LV patcher (most lines changed)  |

---

## Phase plan

Each phase is **independently shippable**. Stopping after any phase leaves the
codebase strictly improved. Estimates assume one engineer working focused.

### Phase 0 — Manifest foundation (1–2 weeks)

Set up the substrate that everything else builds on. Pure win, low risk, no new
tools committed yet.

**Deliverables:**

- `:static_nifs` config block schema added to `mob.exs` (defined in `mob_dev`)
- `mix mob.regen_driver_tab` task in `mob_dev` that produces
  `driver_tab_ios.c` + `driver_tab_android.c` from the manifest
- `mob`'s existing `driver_tab_*.c` files become base templates with extension
  points (or get reduced to "this is generated, do not edit" if fully replaced)
- `mob_new` build templates updated to compile the per-app generated driver_tab
- `mix mob.regen_driver_tab` runs as part of `mix compile` so files stay in sync
- `mob.doctor` warns about manifest drift
- Smoke test: fresh `mix mob.new` → `mix mob.deploy --native` produces working
  app with byte-equivalent driver_tab to today's hand-edited version

**Repo touch:** mob (driver_tab pattern), mob_dev (task + schema), mob_new
(template updates).

**Stop criterion:** Manual driver_tab editing is eliminated. No tool commitments
beyond Elixir.

### Phase 1 — `zig cc` as drop-in C compiler (half-day to 1 week)

Lowest-risk Zig commitment. Validates the toolchain decision before bigger
commits.

**Deliverables:**

- `mob.doctor` checks for `zig` on PATH; warns if missing
- `scripts/release/*.sh` in `mob_dev` swap `xcrun cc` / NDK clang for
  `zig cc -target ...`
- `mob_new`'s `priv/templates/mob.new/ios/build.sh.eex` + LV equivalent in
  `lib/mob_new/live_view_patcher.ex` swap `CC` to `zig cc`
- Smoke test: full deploy on iOS sim + Android emulator; produced binaries
  byte-equivalent or behaviorally identical
- `.tool-versions` in all three repos pins a Zig version (treat like the OTP
  pin — bump deliberately)

**Repo touch:** mob_dev (release scripts), mob_new (build templates).
**No mob changes.**

**Stop criterion:** Single C toolchain across all platforms. If `zig cc`
doesn't pan out for some target, half-day spike already revealed it.

### Phase 2 — `build.sh` → `build.zig` for one platform first (3–6 weeks)

Pick **iOS sim vanilla** as the first target because it's the simplest path
with the tightest reference. Validate end-to-end. Then expand to LV iOS,
Android arm64, Android arm32, iOS device — one platform per ~1 week.

**Deliverables:**

- `priv/templates/mob.new/ios/build.zig.eex` template in `mob_new`
- Mob_dev's `mob.deploy --native` invokes Zig build via the platform's outer
  packager (xcodebuild for iOS, gradle for Android)
- `build.sh` files kept as `build.sh.legacy.eex` for one release cycle as
  rollback
- Per-platform smoke tests: `mix mob.new` + `mix mob.deploy --native` produces
  working app; the migration runs after the existing-platform tests pass
- Incremental builds genuinely incremental (validated via timing — should be
  seconds for no-op rebuild)

**Repo touch:** mob_new (build templates, biggest chunk of work),
mob_dev (deploy task changes minimally), mob (none).

**Stop criterion:** `build.sh` no longer used. Cross-compile orchestration is
declarative + cached + composable.

### Phase 3 — `mix mob.add_nif` Igniter task (2–3 weeks)

Greenfield Igniter usage. No migration cost. Becomes the template for migrating
`mob.enable` and `mob.new --liveview` later.

**Deliverables:**

- `mix mob.add_nif <name> [--type elixir-only|c|zigler|rustler]` in `mob_dev`
- Adds Hex dep if needed; updates `mob.exs` static_nifs manifest
- Generates Elixir stub module via Igniter (AST-aware)
- Generates per-language native source skeleton (templated text)
- Composes with `mix mob.regen_driver_tab` so the manifest update produces
  updated driver_tab in one flow
- Documentation in mob_dev's README + AGENTS.md

**Repo touch:** mob_dev (new task + native templates), mob_new (possibly NIF
source templates if shared).

**Stop criterion:** Adding a new NIF is one CLI call, not five manual edits.

### Phase 4 — `mix mob.enable <feature>` migrates to Igniter (3–4 weeks total, one feature at a time)

The current `mob.enable` does string-based file editing for AndroidManifest.xml,
.entitlements, etc. Migrating to Igniter for the Elixir parts + structured
file ops for non-Elixir parts removes a class of bugs.

**Deliverables (per feature):**

- Refactor each `mob.enable` feature handler to compose Igniter operations
- Elixir-side modifications go through Igniter AST
- Non-Elixir files (XML manifests, plists) stay text-level but use Igniter's
  `create_new_file/3` / `update_file/3` for consistency
- Tests cover each feature's end state from a clean project

**Order:** start with the simplest features (camera, photo_library) before
hitting the complex ones (notifications, liveview). Each is its own commit.

**Repo touch:** mob_dev (one feature handler at a time).

**Stop criterion:** All `mob.enable` features use Igniter consistently.

### Phase 5 — `mix mob.new --liveview` migrates to Igniter (3–4 weeks)

The regex-patched Phoenix flow we already debugged twice (`:re.import/1` and
the Elixir version drift in the OTP 29 rebuild). Highest-value rewrite —
biggest fragility removed.

**Deliverables:**

- `lib/mob_new/live_view_patcher.ex` rewritten to use Igniter for Elixir AST
  modifications (replace every `Regex.replace`/`Regex.compile!` on Elixir code)
- Non-Elixir patches (esbuild config, package.json, root.html.heex injections)
  stay text-level but contained in dedicated helpers
- Regression test exercises the full LV generation flow end-to-end
- Smoke test: `mix mob.new my_lv --liveview` → `mix mob.install` → `mix
  mob.deploy --native --device <emulator>` boots cleanly on Android + iOS sim

**Repo touch:** mob_new (live_view_patcher.ex, the most complex single file
in the repo).

**Stop criterion:** No more regex-patched Elixir source in the LV generator.

### Phase 6 — Polish (ongoing, ship incrementally)

The longer-tail improvements. Each is independently valuable; none gates the
others.

**6a — `driver_tab.zig` comptime-generated from manifest:**
- Convert `driver_tab_*.c` to `driver_tab.zig`
- Use Zig comptime to build the static array from a generated `static_nifs.zig`
- Eliminates the regen step entirely; the table builds itself at Zig compile
- Touches: mob (driver_tab files), mob_new (build.zig references new file)

**6b — Migrate Android C to Zig:**
- `mob/android/jni/mob_nif.c` (~2300 lines) → Zig
- `mob/android/jni/mob_beam.c` (~540 lines) → Zig
- iOS Objective-C stays as-is — ARC handles memory; ObjC's Cocoa idiom is right
- Touches: mob primarily

**6c — OTP rebuild scripts → `build.zig`:**
- `scripts/release/openssl/build_crypto_static_*.sh` → Zig build
- `scripts/release/xcompile_*.sh` → Zig build
- `scripts/release/tarball_*.sh` → Zig build (or stay shell — these are simpler)
- Touches: mob_dev

---

## Per-repo summary

### `mob`

Lightest weight. Most phases are transparent. Direct involvement:

- **Phase 0**: driver_tab files become templates with extension points
- **Phase 6a**: driver_tab → comptime Zig
- **Phase 6b**: Android C → Zig (~3000 lines, the biggest single change to mob
  in this migration)

`mob/ios/*.{m,h}` (Objective-C) **stays as-is** through the entire migration.
ARC + Cocoa idioms are right; rewriting in Zig would be worse.

### `mob_dev`

Most distinct changes — owns Mix tasks and release scripts:

- **Phase 0**: `mob.regen_driver_tab` + manifest schema + `mob.doctor` checks
- **Phase 1**: release scripts use `zig cc`
- **Phase 2**: deploy task invokes Zig build via xcodebuild/gradle
- **Phase 3**: `mob.add_nif` (new Igniter task)
- **Phase 4**: `mob.enable` feature-by-feature migration to Igniter
- **Phase 6c**: release scripts → `build.zig`

Tasks that **don't migrate**: `mob.doctor`, `mob.icon`, `mob.devices`,
`mob.connect`, `mob.push`, `mob.provision`. They work; they don't fit either
new tool.

### `mob_new`

Heaviest absolute change — owns the build templates and LV generator:

- **Phase 0**: build templates reference per-app generated driver_tab
- **Phase 1**: `build.sh.eex` templates use `zig cc`
- **Phase 2**: `build.sh.eex` → `build.zig.eex` (vanilla iOS, then LV iOS,
  then Android variants) — most lines changed across the migration
- **Phase 5**: `lib/mob_new/live_view_patcher.ex` rewrites to Igniter
- **Phase 6a**: build templates reference comptime-generated driver_tab.zig

---

## Coordination concerns

A few cross-repo invariants that need careful handling because mistakes in
these compound across all three repos:

### 1. Manifest schema is one definition, three users

The `:static_nifs` block in user apps' `mob.exs` is read by:
- `mob_dev`'s `mix mob.regen_driver_tab`
- `mob_dev`'s `mix mob.deploy --native`
- `mob_new`'s build templates

**Schema changes are breaking changes for both other repos.** Bump versions
in lockstep. Document the schema in mob_dev's README and link from the others.

### 2. Zig version pin is three `.tool-versions` files

When you bump Zig (treat like OTP version bumps — deliberate, tested), bump in
all three repos in lockstep. Mismatched Zig pins between repos will cause
generated projects to fail compilation in non-obvious ways.

### 3. mob_new generates references to mob's source

Build templates in mob_new reference `${MOB_DIR}/ios/mob_nif.m` etc. **If
mob's file layout changes** (e.g., Phase 6b moves `mob/android/jni/*.c` to
`*.zig`), every mob_new build template needs to reference new paths in the
**same release** that lands the mob change.

### 4. Hex publish order

For each release that crosses repos:
1. Publish `mob` to Hex first (lowest in dep tree)
2. Then `mob_dev` (depends on Hex `mob`)
3. Then `mob_new` (depends on Hex `mob` + `mob_dev`)

When schema or shared layout changes, lockstep publish. When isolated changes,
out-of-order is fine because dep version constraints (`{:mob, "~> 0.5"}`) accept
ranges.

### 5. Worktree-driven parallel execution

This migration is multi-month. Multiple agents may work on independent phases
in parallel. **All work happens in worktrees** (see Worktree section in each
repo's CLAUDE.md). Coordinate phase ownership via this doc — don't have two
agents on the same phase simultaneously.

---

## Risk management

### Working code is precious

The shell-script build pipeline has been debugged through two real-world
incidents (the OTP 28.0 regex bug and the OTP 29.0-rc3 ERTS bump). It works.
**Replacing it has real regression risk.**

Mitigations baked into the plan:

- **Keep `build.sh.legacy.eex` for one release cycle** after Phase 2 lands the
  Zig replacement. Easy rollback if the Zig version has unexpected issues.
- **Validate via byte-equivalence first.** First Phase 2 platform should
  produce a binary that runs identically to the shell-script version. Hash
  the binaries; diff what's different; explain every difference.
- **CI tests at every phase boundary.** Phase 0 adds a test asserting
  `mob.regen_driver_tab` produces stable output. Phase 2 adds a test that
  `mix mob.deploy --native` produces working apps for each platform.

### Zig 0.x churn

Zig is pre-1.0. Every Zig version may break `build.zig`. Mitigations:

- Pin Zig in `.tool-versions` like OTP. Treat version bumps as deliberate
  events, not auto-updates.
- Plan to budget ~1 person-week per year on Zig version migrations. This is
  the explicit cost of being on pre-1.0.
- If Zig 1.0 ships during this migration, plan to reach a consistent
  pre-1.0 baseline first, then upgrade in one coordinated step.

### Don't migrate working tasks just for consistency

`mix mob.doctor`, `mix mob.icon`, `mix mob.devices`, etc. **stay as-is**.
They don't benefit from Igniter or Zig build. Rewriting working code for
consistency's sake is how scope creeps. Leave them.

---

## Branch strategy

**Use `master` once the in-flight `pythonx-support` branches merge.** This
migration is a multi-month sequenced effort; keeping it on master with phase
branches off master gives clean history. Each phase = one PR.

**Pythonx-support coordination**: Phase 0 and Phase 1 are isolated enough to
proceed on a parallel branch alongside Pythonx if Pythonx is still active. From
Phase 2 onward, the migration starts touching mob_new build templates where
Pythonx work also lives — at that point, serialize behind Pythonx merge.

**Worktree-per-phase**: each phase's work happens in its own worktree to
allow parallel agents on different phases without stepping on each other. See
`Worktrees` section in each repo's CLAUDE.md for the convention.

---

## Recommended sequencing across repos for each phase

Per phase, what order to land changes to avoid mid-flight breakage:

**Phase 0 (manifest + regen):**
1. `mob_dev`: define schema + write `mix mob.regen_driver_tab`
2. `mob`: update `driver_tab_*.c` to be base templates
3. `mob_new`: update generated `mob.exs` template + build.sh templates
4. Smoke test: fresh `mix mob.new` → deploy works

**Phase 1 (zig cc):**
1. `mob_dev`: add zig check to mob.doctor + swap CC in release scripts
2. `mob_new`: swap CC in build templates
3. Smoke test on both platforms

**Phase 2 (build.sh → build.zig):**
1. `mob_new`: implement build.zig.eex for one platform (iOS sim vanilla)
2. Validate byte-equivalence with smoke test
3. Expand to next platform; repeat
4. Last step: remove `build.sh.legacy.eex` after one release cycle

**Phase 3+ (Igniter migrations):**
- Per-task migrations land independently. Order by current pain.

---

## Success criteria

The migration is complete when:

1. **Single source of truth**: every NIF appears once in `mob.exs`'s
   `:static_nifs` block; no hand-edited driver_tab anywhere.
2. **Single C toolchain**: `zig cc` is the C compiler driver across all four
   cross-compile targets. No `xcrun cc` / NDK-clang invocations remaining.
3. **Single build orchestrator**: native compile invoked via Zig build (with
   Xcode/Gradle wrapping for app-bundle assembly). No `build.sh` files in
   `mob_new` templates.
4. **Igniter-driven scaffolding**: `mob.new --liveview`, `mob.enable`, and
   `mob.add_nif` all use Igniter for Elixir AST work.
5. **Tests are green** across all three repos at every phase boundary.
6. **Smoke test passes** end-to-end on all four cross-compile targets after
   each phase.

Optional (Phase 6) target state:

7. **Driver_tab is comptime-generated** from a manifest in Zig source.
8. **Android NIF code is Zig** (`mob/android/jni/*.zig`).
9. **OTP rebuild orchestration** lives in `build.zig`, not shell.

---

## Estimated scope

- **Single engineer, full sequence**: ~6 months
- **Two engineers in parallel** (most phases are independent): ~3–4 months
- **Phases 0–2 only** (highest leverage, defensible stopping point): ~2–3 months

Sustained maintenance after migration: roughly equivalent to today's burden,
shifted from "shell script bugs + regex fragility" to "Zig version bumps +
Igniter task evolution." Net: lower because the new shape is more compositional.

---

## Resolved decisions

Greenlit 2026-05-09 alongside Phase 0 kickoff. Updates to these decisions go
here, not in commit messages.

- **Pythonx-support coordination**: merged to master in all three repos on
  2026-05-09 (mob 0.5.18, mob_dev 0.4.0, mob_new 0.2.0). Migration starts on
  the unified master.
- **Manifest format**: per-arch overrides live **in the data**, not as
  preprocessor flags. A NIF entry can specify `archs: [:all]` (default) or
  `archs: [:ios_device, :ios_sim]` etc. More declarative; both Igniter and
  the eventual Zig comptime generator can read it without parsing C macros.
- **Driver_tab location**: **per-app generated**, written to the app's project
  (e.g. `priv/generated/driver_tab_ios.c`). Mob's library-shipped driver_tabs
  become reference snapshots / smoke-test fixtures only. Per-app keeps each
  app's table tied to its actual `:static_nifs` set.
- **Zig version pin**: started at 0.15.2 stable (Phase 1, used `zig cc`
  only). Bumped to 0.17.0-dev.269+ebff43698 nightly at Phase 2 because
  `zig build` on macOS 26.x (Sequoia/26 SDK) is broken in 0.15.x — even
  an empty `pub fn main() void {}` fails to link with missing libSystem
  symbols (`__availability_version_check`, `_realpath$DARWIN_EXTSN`,
  etc.). Nightly has the macOS 26 fix. Plan: switch to a Zig stable that
  contains the fix when one exists (likely 0.17.0). Captured in
  `.tool-versions` across all three repos. Bump deliberately, like the
  OTP pin.
- **Igniter version**: pin to latest stable when Phase 3 starts; track
  upstream releases.
- **Branch strategy**: one worktree per phase per repo. Branch names follow
  `migration/phase-<N>-<slug>` (e.g. `migration/phase-0-manifest`). Each
  phase = one PR per affected repo, merged in the order in "Recommended
  sequencing".

---

## Updates

Append progress notes here as phases complete.

### 2026-05-09

**Phase 0 complete.** `MobDev.StaticNifs` schema + `mix mob.regen_driver_tab`
task in mob_dev (0.4.x). Per-app `priv/generated/driver_tab_<plat>.c` is the
source of truth; mob's library copies stay as fallback for unmigrated
projects. `mob.doctor` warns on drift. Smoke test: full deploy on iPhone 17
Pro sim with both fallback and per-app paths.

**Phase 1 complete.** Pinned zig 0.15.2 in `.tool-versions` lockstep across
mob/mob_dev/mob_new. `mob.doctor` checks for zig on PATH. iOS sim build
template uses `zig cc` for plain `.c` (driver_tab_ios.c, enif_keepalive.c)
and Apple's `xcrun cc` for `.m` files (zig's bundled clang can't build
Apple framework module maps under -fmodules — Phase 1 finding).

**Phase 2 in progress** — iOS sim vanilla complete through link.

  - 2026-05-09: bumped zig pin to 0.17.0-dev nightly. Zig 0.15.x can't
    link the build runner itself on macOS 26.x — even an empty
    `pub fn main() void {}` fails with missing libSystem symbols. The
    nightly has the fix; planning to switch to a zig stable that ships
    the macOS 26 fix when one is released (likely 0.17.0).

  - iter 1: build.zig owns driver_tab_ios.c compile.
  - iter 2: + enif_keepalive.c compile.
  - iter 3: + 5 ObjC compiles via xcrun cc system commands
    (MobNode/mob_nif/mob_beam/AppDelegate/beam_main).
  - iter 4: + Swift compile via xcrun swiftc system command. Swift→ObjC
    header dependency wired through the build graph via
    `addPrefixedDirectoryArg("-I", swift_h.dirname())`.
  - iter 5: + final link via xcrun swiftc system command. Produces the
    Mach-O binary directly. build.sh shrank from ~390 → ~325 lines.

  - iter 6: bundle + simctl install moved out of build.sh into
    `MobDev.NativeBuild`. build.sh ends at `=== Native build complete ===`
    after `zig build binary`. Mix takes over: simulator pick (`--device`
    or detect booted), .app bundle assembly, optional `xcrun actool`,
    `xcrun simctl install`. First concrete realization of the layered
    architecture from the plan diagram (Mix → Zig build → Apple
    packagers).

  iOS sim vanilla now matches the plan's target architecture.

  - iter 7: LV iOS template ported to the same `zig build binary` +
    Mix bundle pattern. `live_view_patcher.ex`'s inline build.sh
    string lost ~85 lines of duplicated native build glue; LV-specific
    parts (Phoenix asset build, crypto shim erlc, host ssl beam copy,
    priv/static + priv/repo copies) stay in build.sh as non-native
    concerns. Smoke-tested with `mix mob.new lv --liveview` end-to-end
    on iPhone 17 Pro sim — 837 BEAM files (Phoenix deps), Mach-O
    binary at ios/zig-out/, app launches.

  - Android Phase 0 validation (no new code): deployed phase2f_smoke
    to emulator-5556 with Phase 0's per-app
    `priv/generated/driver_tab_android.c` resolved by the
    CMakeLists.txt `if(EXISTS ...)` fallback. APK built via
    Gradle → CMake → NDK clang, BEAM pushed, app started. Confirms the
    Phase 0 substrate works on Android end-to-end. CMake → build.zig
    swap is still pending Phase 2 work.

  - iter 8: Android arm64 + arm32 — driver_tab_android.c moves into a
    new `android/app/src/main/jni/build.zig`. Per-ABI invocation:
    arm64-v8a → aarch64-linux-android, armeabi-v7a → arm-linux-androideabi.
    Mix's NativeBuild invokes `zig build c-objects` once per ABI before
    `gradle_assemble`; outputs land at
    `android/app/build/zig-out/<abi>/driver_tab_android.o`.
    CMakeLists.txt grew a three-tier fallback (zig-out .o → Phase 0 .c
    → mob's reference .c) so non-Mix invocations (Android Studio "Sync
    Project") still work. Smoke-tested on emulator-5556.

  - iter 9: All four Android C compiles (mob_nif.c, mob_beam.c,
    beam_jni.c, driver_tab_android.c) into build.zig. CMake's
    `add_library` becomes a `.o`-only target with explicit
    `LINKER_LANGUAGE C` (CMake can't infer linker driver from .o
    sources alone). Four NDK discoveries needed to make zig cc + NDK
    headers play together:
      1. zig 0.17 needs API-versioned target via target query's
         `os_version_min`, not `aarch64-linux-android24` CLI form.
      2. NDK header search: `--sysroot=$NDK_SYSROOT` plus two
         `-isystem` paths — `$SYSROOT/usr/include` (jni.h, android/*)
         and `$SYSROOT/usr/include/<arch-triple>` (sys/, linux/, etc.).
      3. `-fPIC` required (zig cc doesn't add it; NDK clang does).
      4. NDK sysroot path is detected from
         `$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/<host>`
         where host is `darwin-x86_64` even on Apple Silicon.

  - iter 10: Android link → build.zig produces per-ABI lib<app>.so
    via NDK clang (zig cc handles compile; switching to NDK clang for
    the link sidesteps zig's "unable to provide libc for target"
    rejection on Android). Output lands in
    `android/app/src/main/jniLibs/<abi>/` where Gradle's default
    jniLibs.srcDirs scan picks it up. CMakeLists.txt adds an IMPORTED
    target so sqlite3_nif's link still finds the SONAME — without
    `IMPORTED_SONAME` matching `-Wl,-soname` from the build.zig link,
    sqlite3_nif's DT_NEEDED carries the absolute build-host path and
    runtime dlopen fails. Smoke-tested on emulator-5556: BEAM started,
    Repo migrations ran, exqlite NIF loaded, full UI rendered.

    Seven NDK + zig discoveries logged in the iter 10 commit message
    (`-Wl,--allow-multiple-definition` unsupported, sysroot-relative
    -L paths, libc-provisioning rejection, libstdc++ vs libc++
    naming, -lm for math, SONAME wiring, IMPORTED_SONAME).

  - iter 11: sqlite3_nif compile + link into build.zig. The exqlite
    NIF's link explicitly pulls lib<app>.so so its DT_NEEDED entry
    carries the SONAME — Android's loader maps lib<app>.so first and
    enif_* symbols resolve at runtime. (First attempt used
    --allow-shlib-undefined and skipped the explicit link; the link
    succeeded but runtime dlopen failed with "cannot locate symbol
    enif_make_int".) Smoke-tested on emulator-5556: both .so files in
    jniLibs, BEAM started, both Repo migrations ran, exqlite loaded,
    full UI rendered.

    **Phase 2 Android is now CMake-free for the compile/link path.**
    CMake still configures the build (Gradle requires a CMakeLists.txt
    for externalNativeBuild), but its add_library blocks only execute
    as fallbacks when build.zig didn't run.

  - iter 12: iOS device build_device.zig — sister to ios/build.zig
    targeting iphoneos. Compiles the same 7 standard sources (5 ObjC,
    1 Swift, driver_tab + enif_keepalive) for arm64-apple-ios17.0 with
    SDK iphoneos. mob_beam.m gets -DMOB_BUNDLE_OTP / -DERTS_VSN /
    -DOTP_RELEASE; driver_tab gets optional -DMOB_STATIC_SQLITE_NIF
    via the sqlite_static option. EPMD compile, erl_errno_id_compat
    stub, the link, .app bundle, codesign, and devicectl install all
    stay in build_device.sh for this iter — they migrate as iter 12b/c.

    Smoke-tested via pythonx_ios_spike on a real iPhone: build pipeline
    end-to-end works — all 8 .o files produced as Mach-O 64-bit arm64
    (device, not simulator), link succeeded, .app bundled, codesign
    signed all 66 Python lib-dynload + Python framework + libpythonx.so
    + the main binary. Install hit a provisioning-profile error on the
    device — orthogonal to the build pipeline.

  - iter 12b: EPMD + erl_errno_id_compat into build_device.zig.
    12 .o files now flow through build.zig (5 ObjC + 1 Swift + 2 plain
    C + 3 EPMD + 1 errno shim).

  - iter 12c: iOS device link → build_device.zig. xcrun swiftc with
    OTP/crypto static libs + optional sqlite3_nif.a + frameworks +
    -dead_strip → Mach-O binary at ios/zig-out/<display_name>.

  - iter 12d: bundle + codesign + devicectl install → Mix. ~180 lines
    of bundle/codesign/install glue moved out of build_device.sh into
    Elixir. The Mix-driven flow includes:
      - .app bundle assembly (PlistBuddy CFBundleIdentifier/Executable
        /Name patches, conditional actool for AppIcon)
      - OTP runtime bundling (rsync lib/releases/<app>/python/ + logos
        + ERTS_VSN/bin dir)
      - Slim strip (placeholder; TODO to port the shell version)
      - Provisioning profile embed (checks both Xcode UserData + older
        MobileDevice paths)
      - Codesign bottom-up (Python lib-dynload .so → Python.framework
        → libpythonx.so → .app with entitlements)
      - devicectl install
    Smoke-tested on Kevin's iPhone: full end-to-end success including
    install. The Mix-driven path resolved an install-acceptance issue
    the shell flow had hit at the device-trust layer.

  - iter 13a: slim_step pipeline restored in Elixir (was a TODO in
    iter 12d's bundle/codesign migration). Mirrors the original shell
    version: apple binaries strip, prefix libs strip, foreign apps
    strip, dedup versions, src+headers strip, beam chunk strip via
    `:beam_lib.strip_release/1`. Gated on `MOB_SLIM=1` to keep dev
    iteration fast (the strip pass adds ~5-10s).

  - iter 13b: iOS sim build glue → Mix. The generated
    `ios/build.sh.eex` template (288 lines) is gone. All iOS-sim
    build glue (mix compile, BEAM copies, exqlite NIF cross-compile,
    Pythonx framework + cross-compile, crypto shim for LV,
    ssl beams from host OTP for LV, Phoenix asset build for LV,
    Ecto migration copy, Elixir/EEx stdlib copy, OTP runtime sync,
    enif_keepalive generation, zig binary build, .app bundle, simctl
    install) now flows through MobDev.NativeBuild. LV detection gates
    on `assets/` at project root (not on transitive phoenix_live_view
    dep — vanilla mob pulls it in too). Smoke-tested LV (Phoenix 1.7)
    and vanilla mob projects on both iOS sim and physical iPhone.
    Companion mob_new commit removes `liveview_build_sh_content/2`
    and the build.sh template.

  - iter 13c: eliminate `build_device.sh`. Same model as iter 13b but
    for iOS device. `generate_build_device_sh/2` (~520 lines) is gone;
    `build_ios_physical/2` is now a `with` chain over Mix helpers.
    Reuses iter 13b helpers verbatim (compile, beam copy, exqlite OTP
    lib, crypto shim, Elixir/EEx stdlib, migrations, Phoenix assets,
    enif_keepalive). Adds device-specific helpers:
    cross_compile_exqlite_nif_device (static .a, iphoneos arm64);
    maybe_setup_pythonx_device (Python.framework rsync +
    libpythonx.so for iphoneos arm64); maybe_install_ssl_shim
    (LV-only full SSL stub); copy_otp_libs_for_phoenix (runtime_tools,
    asn1, public_key from host OTP); install_app_in_otp_lib (so
    Plug.Static's :code.lib_dir resolves); copy_mob_logos_to_otp_root;
    patch_epmd_source (idempotent NO_DAEMON guard);
    generate_erl_errno_compat_stub; zig_build_binary_ios_device.
    Stale references swept: `has_ios_project?/0` in mob.doctor +
    mob.install now checks `ios/build.zig`; doctor python3/rsync
    rationale + battery_bench docstring updated; enable.ex's
    detect_stale_pythonx_templates drops the obsolete build.sh entries.
    Smoke-tested LV (Phoenix 1.7) and vanilla mob on Kevin's iPhone:
    both deploy clean.

  - iter 13d: release scripts → zig cc — **researched, blocked, deferred**.
    Goal was to swap `xcrun -sdk … cc` (and Android NDK clang) for
    `zig cc -target …` in `scripts/release/xcomp/erl-xcomp-*.conf` so
    the OTP tarball is built with the same toolchain the dev path uses.

    **What works:**
    - zig cc 0.17.0-dev compiles + links iOS sim/device executables
      with these specific flags (verified via standalone hello-world):
        `zig cc -target aarch64-ios-simulator -nostdlibinc \`
        `       -isysroot $SDK -isystem $SDK/usr/include -L$SDK/usr/lib`
      The `-nostdlibinc` is required because zig's bundled stdlib
      headers don't match iOS; `-isystem $SDK/usr/include` provides
      Apple's iOS SDK headers explicitly (NOT picked up via
      `-isysroot` alone in zig 0.17.0-dev).
    - With these flags, OTP's autoconf passes `checking whether the
      C compiler works... yes` for every subdir.
    - Several OTP libraries (erl_interface, ei) build cleanly.

    **What blocks:**
    - zig cc tries to provide its own libc++ when `-lc++` is in
      LDFLAGS, which fails for iOS sim with cascade of "unknown type
      mbstate_t / wint_t / size_t" errors against zig's bundled
      libcxx headers (zig doesn't ship iOS-sim libc fragments).
      Workaround: drop `-lc++` from LDFLAGS — works for OTP since
      `--disable-jit --without-wx` removes the only C++ surfaces.
    - After getting past configure + early lib builds, OTP's
      emulator build fails:
        `gmake[4]: *** No rule to make target 'stdbool.h', needed by`
        `'obj/aarch64-apple-iossimulator/opt/emu/erl_main.o'.  Stop.`
      Root cause: OTP's emulator Makefile.in uses `-MM -MG` for its
      custom dep-generation pass (`$(SED_DEPEND) $@.tmp > $@`). With
      zig cc, `-MM` outputs only user headers + zig's stdbool.h
      absolute path (`/Users/kevin/zig/.../include/stdbool.h`),
      which OTP's SED_DEPEND step rewrites to a bare basename that
      then has no make-rule to satisfy it. Apple's clang outputs
      similar absolute paths but OTP's SED_DEPEND was tuned to its
      output format. Patching OTP's emulator dep machinery to
      tolerate zig's output format is OTP-internal engineering, not
      Phase 1 cleanup work.
    - Android: zig 0.17.0-dev rejects `aarch64-linux-android24` as
      `UnknownApplicationBinaryInterface`. Workarounds (musl target
      + NDK sysroot) don't survive OTP's autoconf feature tests.

    **Decision:** iter 13d is **deferred indefinitely**. The dev path
    already uses zig cc for everything that matters (driver_tab,
    enif_keepalive, the link via xcrun swiftc — see iter 1-12). The
    release path runs once per OTP version bump (rare) and
    successfully produces working tarballs with `xcrun cc` + NDK
    clang. Pushing the swap through would require:
      1. patching OTP's emulator Makefile.in dep generation, OR
      2. building a `zig-cc-wrapper` shell that translates zig's dep
         output into OTP-friendly format
    Neither is justified by the marginal benefit (one-fewer
    toolchain on the release machine, which is Kevin's Mac that
    already has Xcode + NDK). Revisit when zig has first-class Apple
    SDK + Android NDK support, or if a future OTP cleanup makes the
    emulator dep machinery less custom.

  - iter 13e: timing validation. Measured no-change rebuild on iOS
    sim (vanilla phase2q_smoke project): 2m12s end-to-end. Time is
    dominated by:
      - OTP runtime rsync to `~/.mob/runtime/ios-sim` (~195 MB)
      - exqlite NIF cross-compile (always re-runs)
      - .app bundle rebuild (full rsync of OTP into the bundle)
    All three are operations the old shell pipeline did unconditionally
    too — iter 13b/c preserves the original semantics, no regression.
    Future caching wins (skip rsync when sources unchanged, mtime-
    gated exqlite recompile, content-hashed bundle reuse) are out of
    scope for Phase 2 cleanup; tracked as separate optimization work.

  **Phase 2 is COMPLETE.** Every target — iOS sim vanilla, iOS sim
  LiveView, Android arm64, Android arm32, Android sqlite3_nif, iOS
  device — has its native compile + link in build.zig and its
  bundle/install in Mix (or Gradle for Android). Both
  `ios/build.sh.eex` and runtime-generated `build_device.sh` are
  gone. The iOS path no longer uses shell scripts at all; build
  orchestration lives in Elixir (`mob_dev/lib/mob_dev/native_build.ex`)
  and Zig (`build.zig` / `build_device.zig`).

## Phase 3 — `mix mob.add_nif` (in progress)

Greenfield Igniter usage. First commit to Igniter as a dep; lays the
groundwork for the Phase 4/5 rewrites by validating the AST-aware
generator pattern on a small, self-contained task.

  - iter 1: scaffold task. `mix mob.add_nif <name> [--type elixir-only|c]`
    creates `lib/<app>/nifs/<name>.ex` (Elixir stub via
    `Igniter.Project.Module.create_module`), appends
    `%{module: :<name>, archs: [:all]}` to `mob.exs`'s `:static_nifs`
    via `Igniter.Project.Config.modify_config_code/5`, and (with
    `--type c`) drops a `c_src/<name>.c` skeleton with
    `ERL_NIF_INIT(<name>, ...)` pre-wired. Validates name is
    snake_case + length-bounded; `--type` is `elixir-only` or `c`
    (zigler/rustler land in later iters that pull in those Hex deps).
    Idempotent — re-running with the same name skips file writes and
    keeps the existing list entry. Drive-by fix: `mix mob.regen_driver_tab`
    was reading from `Application.get_env(:mob_dev, :static_nifs, [])`
    but mob.exs is not auto-imported into Mix application env, so the
    user's `:static_nifs` entries never reached driver_tab. Switched
    regen to `MobDev.Config.load_mob_config()` matching every other
    mob_dev task. Smoke-tested against `phase2q_smoke`: deploy added
    one NIF, regen produced driver_tab containing the entry, second
    add appended to the existing list cleanly. 20 new tests covering
    validation/stub/append/idempotence/C-skeleton/notice paths.
    `igniter ~> 0.8` added to mob_dev deps (the Phase 3 dep
    commitment). 850/850 tests pass on mob_dev master.
