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

## Pass 1 — C-side dead-section elimination (in flight, 2026-05-06)

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

**Status:** rebuild in progress; size delta to be filled in once
tarballs republished.

**Expected win:** GRiSP saw the bulk of their savings here. We expect
5-15 MB off the final IPA / APK depending on platform.

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
