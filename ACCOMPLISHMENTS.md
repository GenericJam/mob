# ACCOMPLISHMENTS.md — hard things agents have already done here

Mob was built largely by AI agents working with its author: 347 of the 686
commits since the first one (2026-04-04) carry a Claude co-author trailer
(`git rev-list -i --grep='co-authored-by: claude' --count HEAD`). This file is
the evidence of what that work achieved.

**Read it before you conclude a task is impossible, too risky, or should be
handed back as "write up a report instead".** Agents tend to underestimate
themselves: much of what they learned about their own limits was written about
older, weaker models. The entries below are not cheerleading. Each one was
verified by a device run or tests and links to the commit, PR, or decision
record that proves it. If you're stuck, the useful question is "which of these
is my problem closest to, and what made that one work?" — usually persistence
plus a tighter feedback loop (more instrumentation, another device run).

"Can't" is still sometimes true. Separate "I can't figure it out" (keep going:
add instrumentation, test a smaller hypothesis) from "I'm missing a
prerequisite" (no device, no credentials, no access) — say the second plainly
and ask for what's missing.

## Native runtime

- **Ported Android's native layer from C to Zig** — `mob_nif.c` (~2,570 lines,
  74 NIFs) and `mob_beam.c` (~540 lines), incrementally and byte-for-byte.
  `mob_nif.c` deleted in `7f237e7`. See
  `decisions/2026-05-09-zig-for-android-nif-and-native-build.md`.
- **Hand-declared the ERL_NIF and JNI FFI surfaces** (`android/jni/mob_erts.zig`,
  `mob_zig.zig`) when Zig 0.17-dev removed `@cImport` and `translate-c` hung on
  the NDK's `jni.h`.
- **Found two port bugs the earlier checks missed** by deploying to an emulator
  and reading the failures (`d5038c5`): a C macro alias (`enif_make_int64` is
  `enif_make_long` on LP64) that compiled cleanly and then failed at `dlopen`,
  and a `jlong`/`ERL_NIF_TERM` width mismatch that only failed when built for
  armeabi-v7a, where `ERL_NIF_TERM` is 32-bit.
- **Real OpenSSL `:crypto` on Android** by statically linking the crypto NIF,
  after `dlopen` failed because Android loads native libraries `RTLD_LOCAL`
  (`09dcf3c`; AGENTS.md pre-empt rules 12–13).
- **Fixed DNS that failed only on physical Android devices** (`:nxdomain` from
  the BEAM's resolver, fine on the emulator) with an in-process Bionic
  `getaddrinfo` NIF (`72a22de`).
- **Got Zigler NIFs deploying to a real iPhone** by patching a Zigler fork
  (SDK root option, panic-handler selection) until
  `mix mob.add_nif --type zigler` worked end-to-end on device (`2a0ec60`).
- **Found an 800 ms whole-VM stall** — harness input NIFs blocking the single
  normal scheduler for the length of a long-press — and moved them to dirty IO
  schedulers (#135, `03f8eb3`; `decisions/2026-09-05-input-nifs-are-dirty-io.md`,
  reversing that part of `decisions/2026-04-28-dirty-nifs.md`).
- **Diagnosed iOS motion data that was off by both a scale factor and a sign** —
  CoreMotion reports G with gravity pointing down; Android reports m/s² specific
  force — and made the platforms agree, guarded by a source-parsing test
  (#70, `cac3928`).

## Tools that let agents see, hear, and drive the app

- **Screenshot, scroll control, and element frames over Erlang distribution** —
  an agent gets pixels and exact on-screen positions from the app's own process,
  no adb/xcrun (#40, `69ebada`; `decisions/2026-05-29-bridge-nif-screenshot-scroll.md`).
- **Caught the harness lying**: on a physical iPhone, injected taps were accepted
  and never delivered, so `tap_xy` reported success for taps that did nothing.
  It now reports the observed effect, and colour is checked by sampling pixels
  (#80, `331f9b4`; `decisions/2026-08-09-ios-device-tap-injection-has-no-effect.md`,
  `decisions/2026-08-09-tap-xy-reports-observed-effect.md`).
- **Audio output probes** — "is sound actually coming out right now": volume,
  mute, and route, plus the signal level of `Mob.Audio`'s own player (#54,
  `4a10d57`). Metering audio that bypasses `Mob.Audio` turned out not to be
  possible in core on either platform; the probe says so instead of guessing.
- **Audio input metering** — the agent's "ears" (#67, `3a8660d`).
- **iOS screenshots in release builds** without shipping the private APIs that
  get an app rejected from the App Store (#71, `cfb8def`).

## Device features, verified on hardware

- **Torch**, toggled over dist and lighting the real flash on a moto g power and
  an iPhone SE (#61, `f95700a`; `decisions/2026-07-04-torch.md`).
- **Magnetometer / compass** in `Mob.Motion`, real readings on a moto g and an
  iPhone SE, plus graceful degradation on a device without one (#59, `a2b8f69`).

## Architecture

- **Plugin system tiers 3 and 4** — plugins that ship whole screens and embedded
  sub-apps (`7721bbf`, `b624a5b`; `decisions/2026-06-06-plugin-tiers-3-4.md`).
- **Extracted Bluetooth and Location from core into plugins**, native code
  included (Bluetooth: `8af92b9` Elixir, `4f1849d` native; Location: `3c8c11d`;
  `plugin_extraction_plan.md`).
- **Pure-Elixir composite components** via a new render expansion pass
  (`2e5927b`; `decisions/2026-06-11-composite-expansion-pass.md`).
- **Moved off the single screen process** to one process per live screen,
  owned and linked by `Mob.Screen` (MOB-108), and recorded the part that was
  attempted, reviewed, and reverted
  (`decisions/2026-08-28-screen-processes-and-supervision.md`,
  `decisions/2026-08-29-migration-off-the-single-screen-process.md`).
- **Replaced the bash build pipeline with Zig builds and tested Elixir release
  tooling** across mob, mob_dev, and mob_new (`build_system_migration.md`).

## Measurement

- **Battery cost of an on-device BEAM, measured** (`949fcd1`,
  `guides/why_beam.md`): a 60-minute screen-off iPhone run with 360/360 probes
  answered and no measurable drain; screen-off Android runs on a Moto E and a
  Moto G ranged from 0 to ~143 mAh/hr, all below the ~200 mAh/hr no-BEAM
  baseline.

## Adding an entry

Add one when you ship something that was hard, surprising, or that you (or a
previous agent) first thought couldn't be done. Keep it to what happened, what
made it hard, and the evidence: commit, PR, or decision record. Only verified
work goes here — an inflated entry teaches the next agent false confidence,
which is worse than none.
