# Slimming Passes — beyond the first 45 → 19.8 MB cut

Working tracker for incremental size reductions to the on-device OTP
runtime. Companion to:

- [`mob_dev/guides/slim_release.md`](../mob_dev/guides/slim_release.md) —
  what we already ship (the 45 → 19.8 MB cuts).
- [`mob_dev/lean_release_extraction.md`](../mob_dev/lean_release_extraction.md) —
  decision to extract the audit + slim tooling as a standalone Hex
  package once APIs stabilize.
- [`crypto_plan.md`](crypto_plan.md) — companion infrastructure rebuild
  (real crypto static-linked) that Pass 1 piggybacks on.

## Pass 1 — C-side dead-section elimination (✅ shipped, 2026-05-06)

**Source of inspiration:** [GRiSP nano writeup
(2025-06-11)](https://www.grisp.org/blog/posts/2025-06-11-grisp-nano-codebeam-sto)
— same flags they used to fit the BEAM into 16 MB of OctoSPI DRAM.

**Mechanic:** `-Os -ffunction-sections -fdata-sections` at compile,
`-Wl,--gc-sections` (Android) / `-Wl,-dead_strip` (iOS) at link. The
linker drops every C function and global object that no live symbol
references. C-side analog of `:beam_lib.strip_release/1` for `.beam`
files.

**Applied to:**
- Four OTP cross-compiles (`xcomp/erl-xcomp-*-android.conf`,
  `xcomp/erl-xcomp-arm64-ios{,simulator}.conf`).
- Four OpenSSL cross-compile scripts (`mob_dev/scripts/release/openssl/`).
- Custom `build_crypto_static_*.sh` (-fPIC NIF rebuild).
- Android CMakeLists template + iOS `build.sh.eex` template.
- iOS-device link in `mob_dev/lib/mob_dev/native_build.ex`.

**Status:** ✅ rebuild + republish complete. Verified pigeon boots
through `step 5 => ok` on Android emulator (arm64) and iOS simulator
(arm64).

**Measured wins (final binary, post `--gc-sections` / `-dead_strip`):**

| Target | Before | After | Δ |
|---|---|---|---|
| Android arm64 `libpigeon.so` | 10.11 MB | 9.25 MB | **-0.86 MB (-8.5%)** |
| iOS sim `Pigeon` binary | 8.02 MB | 7.00 MB | **-1.02 MB (-12.7%)** |
| Android arm32 `libpigeon.so` | n/a | 5.32 MB | new platform online |

Tarball deltas are smaller (the static `.a` archives went up modestly
from per-section padding, partially offsetting the BEAM strips):

| Tarball | Before | After |
|---|---|---|
| `otp-android-73ba6e0f.tar.gz` | 79.43 MB | 79.09 MB |
| `otp-android-arm32-73ba6e0f.tar.gz` | 68.49 MB | 68.30 MB |
| `otp-ios-sim-73ba6e0f.tar.gz` | 54.89 MB | 54.23 MB |
| `otp-ios-device-73ba6e0f.tar.gz` | 57.07 MB | 56.42 MB |

The right metric is the **shipped binary**, not the source tarball.
~10% off the iOS app and Android native lib for one config-only change
is the expected outcome from the GRiSP recipe.

**Republished:** `otp-73ba6e0f` GitHub release re-uploaded with the
Pass 1 tarballs. Existing user caches auto-invalidate (no schema
change needed; `valid_otp_dir?/2` re-downloads when content
verification mismatches the on-disk metadata).

## Pass 2 — `unicode_util` stub (proposed)

**Mechanic:** OTP's `unicode_util.beam` carries ~500 KB of Unicode
normalization tables (case-folding, NFC/NFD decomposition, grapheme
break tables). GRiSP's `00700-disable-unicode.patch` replaces it with
a minimal stub.

**Risk:** anything calling `:unicode_util.casefold/1`,
`:unicode_util.normalize/2`, or `:unicode_util.gc/1` breaks.
Surveying mob + peer_net + Phoenix's transitive call graph for
unicode_util usage is the first task.

**Plan:**
1. Audit `:unicode_util` callers reachable from a typical Mob app.
   Most plug_crypto / Phoenix paths use byte-level routing; the
   Unicode tables only matter for explicit normalization (e.g.
   stringprep, IDN URLs).
2. If unreached, ship a `unicode_util_mob.beam` that no-ops the
   normalization functions and forwards the trivial ones (`is_letter/1`
   etc.) to Erlang's char-class BIFs.
3. Wire it through `mob_dev`'s deployer the same way the legacy crypto
   shim was shipped — push next to the app's BEAMs so it shadows the
   OTP version on the on-device code path. (Or: replace it inside the
   OTP runtime tarball at staging time so the cache pre-strips.)

**Expected win:** ~500 KB. Modest, but high signal-to-noise — it's a
known leaf module with a known cost.

**Open question:** the Mob renderer builds Compose/SwiftUI text nodes
from Erlang strings. Compose handles its own normalization; SwiftUI
likewise. The Erlang side may not exercise `:unicode_util` at all in
practice. Need to confirm before stubbing.

## Pass 3 — `mix_unused` against project source (proposed)

**Mechanic:** `mix_unused` (Hauleth) does static AST analysis of
project source and flags public functions that are never called.
Different layer than `OtpAudit` — that's about reachability across
*shipped* application bytecode; `mix_unused` is about source-level dead
code in repos *we author*.

**Plan:**
1. Add `{:mix_unused, "~> 0.4", only: [:dev], runtime: false}` as a
   dev-only dep in `mob_dev` first (least dynamic dispatch in the
   three repos — highest signal).
2. Run `mix compile --warnings-as-errors --force` and inspect the
   `MIX_UNUSED:` warnings.
3. Maintain an `ignore` list for known-dynamic-dispatch entry points
   (mob_nif on_load callbacks, GenServer handle_*, behaviour
   implementations).
4. Decide whether maintenance burden vs signal pays for itself before
   propagating to `mob` and `peer_net`.

**Expected win:** unknown until we run it. Probably small for
recently-written code; could surface dead public functions left from
refactors.

**Risk:** false positives from `apply/2,3`, message dispatch, NIF stubs,
behaviour callbacks. The ignore list is the long-term cost.

## Pass 4 — OpenSSL feature surgery (proposed, lower priority)

**Mechanic:** OpenSSL Configure supports `no-X` flags for many
algorithms. We use a tiny slice of OpenSSL: x25519, ChaCha20-Poly1305,
SHA-256/HKDF, AES-GCM (for ssl), RSA (for X.509 cert verify).

**Plan:**
1. Survey what OpenSSL EVP names the `:crypto` Erlang API actually
   touches when running our test apps end-to-end.
2. Identify safe `no-` flags: `no-md2 no-rc2 no-rc4 no-idea no-mdc2
   no-cast no-blake2 no-bf no-camellia no-seed no-aria` etc.
3. Bench shrink against current Pass 1 binary.

**Expected win:** 2-5 MB off the final binary after `--gc-sections`
already removed unreferenced code. This is the long tail; Pass 1
should already get most of it.

## Pass 5 — Empirical trace harness (already partial — `mix mob.trace_otp`)

**Mechanic:** `mix mob.trace_otp` exists today; it instruments the
basic Elixir/OTP surface (collections, strings, processes, errors)
and returns the actual MFAs hit. Static analysis (`mix mob.audit_otp`)
misses dynamic dispatch; the trace catches it.

**Plan:**
1. Expand the synthetic harness to exercise more of what real apps do
   (Phoenix request flow, Ecto queries, supervisor restarts, GenServer
   callbacks).
2. Capture per-app traces from running apps (`square_triangle`,
   `air_cart_max`, `pigeon`) on actual devices.
3. Treat the union of static reachability + empirical trace as the
   minimum-viable set; everything outside is a strip candidate.
4. Wire into `mix mob.audit_otp` as a new tier in
   `OtpAudit.report` (`:trace_data`, planned in `lean_release_extraction.md`).

**Expected win:** unclear — depends on whether the static analysis
already catches most of what's actually used. The case where this
pays off is unreachable-via-static-call but dynamic-dispatch-reachable
(behaviour callbacks, etc.).

## Order of operations

1. **Finish Pass 1** (in flight). Measure delta. Republish tarballs.
2. **Pass 2 (Unicode stub)** — a single test app run can validate
   nothing breaks. Cheap.
3. **Pass 3 (mix_unused on mob_dev)** — installation + ignore-list
   pass. Possibly extract findings into a separate `dead_code.md`.
4. **Pass 5 (trace harness expansion)** before Pass 4. The trace data
   informs which OpenSSL features to keep.
5. **Pass 4 (OpenSSL feature surgery)** — last, because by then the
   Pass 1 dead-section work has already done the bulk of the OpenSSL
   shrinking.

Skip in this order if a pass turns out to break something or have
diminishing returns.

---

## End-of-session pickups (not slimming, but parked here)

These came up mid-session. They're small and worth doing before we
close out, even though they don't fit the size-reduction theme above.

### NDK 27.2.12479018 detection in `mix mob.doctor` and `mix mob.install`

**Trigger:** beta user feedback (2026-05-06): they hit
`undefined symbol: __cxa_allocate_exception` linking pigeon because
their Android Studio had NDK 25 installed and gradle picked it up;
our `libbeam.a` is compiled with NDK 27 / clang 18 (libc++ inline
namespace `ne180000`). Their phrasing ("my phone needs NDK r25") is a
misframe — phones don't drive NDK choice; the bundled `libbeam.a`
does. They got there through link errors, not a useful diagnostic.

**Mitigation already in place:** `mob_new`'s
`android/app/build.gradle.eex` template pins
`ndkVersion '27.2.12479018'` (committed earlier this session). This
makes gradle pick the right NDK *if it's installed*. The gap is
detection.

**What's missing:** `mob_dev/lib/mix/tasks/mob.doctor.ex` and
`mob.install.ex` don't check whether the required NDK exists at
`$ANDROID_HOME/ndk/27.2.12479018/`. 741 lines of doctor checks; zero
NDK mentions.

**Fix shape:**
1. Constant somewhere (probably `MobDev.Config` or a module attr in
   `mob_dev`'s native build): `@required_ndk_version "27.2.12479018"`.
2. `defp check_android_ndk/0` in `mob.doctor.ex`: looks at
   `<sdk>/ndk/<version>/`, fails loud with the install command:
   `sdkmanager --install "ndk;27.2.12479018"` (or the GUI path:
   Android Studio → SDK Manager → SDK Tools → NDK (Side by side) →
   pick 27.2.12479018).
3. Same check at `mix mob.install` time so users see it during
   onboarding, not the first time they try to deploy.
4. Add a comment to `mob/crypto_plan.md` and the NDK constant
   reminding future-us: when we rebuild tarballs against a new NDK,
   the constant in `mob_dev` and the gradle pin in `mob_new` must
   advance lock-step.

**Effort:** ~30–45 min.

### iOS SDK bump for Liquid Glass out-of-the-box

**Trigger:** iOS 26 ships Apple's Liquid Glass design language. Our
`future_developments.md` (committed earlier) describes the user story:
*"a user who builds an app with Mob ships a Liquid Glass app — nobody
asks what framework this is, it just looks right."* Today, Mob iOS
build scripts target `-miphoneos-version-min=17.0` and we're not
opting into Liquid Glass.

**What's missing:**
1. iOS deployment target bumped to **17.0 + `@available(iOS 26, *)`
   guards** in the SwiftUI rendering layer (so older devices keep
   working, newer ones get Liquid Glass).
2. `mob/ios/MobRootView.swift` and friends apply `.glassEffect()` /
   `GlassEffectContainer` modifiers on iOS 26+ (compile-time gate via
   `if #available(iOS 26.0, *)`).
3. UIKit primitives in mob get `UIBlurEffect` glass-material variants
   on the same platform-version gate.
4. `mob_new`'s iOS template's `Info.plist` and `build.sh.eex` continue
   to target iOS 17 minimum (for compatibility) but are tested
   against the iOS 26 SDK.
5. `mob_dev/build_release.md` notes that the build host needs Xcode
   ≥26 (the SDK that includes Liquid Glass APIs) — and `mob.doctor`
   should warn if the host Xcode is older.

**Effort:** medium. The compile-time `@available` gates and modifier
calls are mechanical (~1 hr); the design choice of *which* Mob
components opt in (sheets, tab bars, custom glass containers, etc.)
is the design call.

**Don't bump min iOS to 26 yet.** That cuts users off from any device
on iOS 17–25. The right framing is: opt into Liquid Glass on iOS 26+,
fall back gracefully on older.
