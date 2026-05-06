# Real-Crypto Tarball Plan

Working document for the framework work to ship real OpenSSL inside the
pre-built OTP tarballs (Android arm64, Android arm32, iOS sim, iOS device).
Mirrors the shape of `app_store_plan.md` and `play_store_plan.md`.

**Status (2026-05-06):** **Android arm64 ✅ working end-to-end.**
Pigeon boots through `step 5 => ok` on the emulator with real
`crypto:generate_key(:ecdh, :x25519)` succeeding, peer_net starting,
SetupScreen mounting. iOS sim + iOS device + Android arm32 still need
the same treatment (WS5 of this plan). Trigger: `pigeon` is the first
mob app needing real on-device crypto (Noise XX handshake over peer_net
uses `:crypto.generate_key/2` with `:x25519`, ChaCha20-Poly1305 AEAD,
and SHA-256 / HKDF-SHA256). Other mob apps (`air_cart_max`,
`square_triangle`, etc.) only used `strong_rand_bytes/1` for UUIDs and
never exercised the `--without-ssl` shim hard enough to notice it was
insecure.

**The seven things that had to land for arm64 to work** (all reusable
for the other three platforms):

1. OpenSSL 3.4.0 cross-compiled for the target arch (`scripts/release/openssl/android_arm64.sh`).
2. OTP cross-compiled `--with-ssl=$OPENSSL_PREFIX --disable-dynamic-ssl-lib --enable-static-nifs LIBS=-L$OPENSSL_PREFIX/lib -lcrypto`.
   `LIBS=-lcrypto` is required so OTP's own `erlexec` link step (which
   transitively pulls in static crypto.a) finds OpenSSL.
3. macOS BSD `ar` cannot make Android ELF archives (silently emits
   empty `.a`). Fix: add `AR=llvm-ar`, `RANLIB=llvm-ranlib` to the
   xcomp conf. See `common_fixes.md`.
4. OTP build emits `lib/crypto/priv/lib/<arch>/crypto.a` without
   `-fPIC` (because the make target is "static archive", not "shared
   library"). When linked into a `.so`, the AArch64 linker complains
   about ADR_PREL_PG_HI21 relocations. Fix: rebuild crypto's C sources
   with `-fPIC` via `scripts/release/openssl/build_crypto_static_android_arm64.sh`,
   overwriting the OTP-built crypto.a in place. Future work: get OTP
   itself to add `-fPIC` to the static-NIF build.
5. `mob/android/jni/driver_tab_android.c` defines its own
   `erts_static_nif_tab[]` that overrides libbeam.a's. **Crypto must
   be added to mob's table**, not just the OTP table — the linker
   takes the strongest definition and mob's wins. Without this step
   the BEAM falls through to dlopen and Android's RTLD_LOCAL hides
   the parent's enif_* symbols.
6. `mob_new`-generated `CMakeLists.txt` adds two link lines:
   ```cmake
   --whole-archive ... ${OTP_DIR}/${ERTS_VSN}/lib/crypto.a
   --no-whole-archive ${OTP_DIR}/${ERTS_VSN}/lib/libcrypto.a
   ```
   Plus `c++abi` after `c++_static` (NDK 27 split the C++ ABI
   symbols out of libc++_static). Plus `ndkVersion '27.2.12479018'`
   pinned in `build.gradle` (matches the NDK that built libbeam.a;
   different NDK = libc++ ABI mismatch).
7. `mob_dev`'s `Deployer.collect_beam_dirs/0` skips the legacy crypto
   shim push when the cached OTP runtime contains
   `lib/crypto-*/ebin/crypto.beam` — otherwise the shim's `crypto.beam`
   shadows the real one in the on-device code path.

---

## Pivot: dynamic crypto.so → static linking only (2026-05-06)

The original plan in this doc described shipping `crypto.so` as a
**dynamic NIF** on Android (and iOS sim) and a static link only on iOS
device for App Store mode. **That's not viable on Android** and we're
revising to static everywhere.

**Why dynamic doesn't work on Android:**

- The mob native lib (e.g. `libpigeon.so`) statically links `libbeam.a`,
  which contains all the `enif_*` API functions.
- Android's dynamic linker loads native libs with `RTLD_LOCAL` by
  default. The parent's symbols are NOT visible to subsequently
  `dlopen`'d children.
- When the BEAM `dlopen`s `crypto.so` to load it as a NIF, `crypto.so`
  references `enif_get_tuple`, `enif_alloc`, etc. The dynamic linker
  can't resolve these because they live in `libpigeon.so` (loaded
  `RTLD_LOCAL` by Java's `System.loadLibrary`).
- Result: `dlopen failed: cannot locate symbol "enif_get_tuple"`.

**Things we tried that don't work:**

- `-Wl,--export-dynamic` on the libpigeon.so link. Adds enif_* to the
  dynamic symbol table, but Android's loader still respects the
  RTLD_LOCAL flag set when libpigeon.so was originally loaded.
- Re-`dlopen`ing libpigeon.so itself with `RTLD_GLOBAL` from inside
  mob_beam.c before `erl_start`. The runtime accepts the call (logs
  confirm), but the existing handle's flags aren't promoted; subsequent
  `dlopen`s from the BEAM can't see the parent's symbols. (See
  Android NDK changelog and bionic source — this is by design;
  `RTLD_GLOBAL` only applies to the children of a library loaded with
  it, not to the loader retroactively.)
- Linking `libc++abi` so the C++ exception ABI symbols resolve. Does
  fix a different earlier failure (libbeam.a uses C++ exceptions and
  NDK 27 split them out of `libc++_static`), but doesn't help with the
  enif_* dlopen issue.

**The static path that works:**

1. OTP configured with `--enable-static-nifs` so the Makefile builds
   `lib/crypto/priv/lib/<arch>/crypto.a` (instead of `crypto.so`) with
   `STATIC_ERLANG_NIF` defined. The init function is renamed to
   `crypto_nif_init` (the static-symbol convention).
2. The Makefile-generated `driver_tab.c` includes `crypto` in
   `erts_static_nif_tab[]` so the BEAM treats it as a static NIF and
   skips `dlopen` entirely — looks up `crypto_nif_init` via
   `dlsym(RTLD_DEFAULT)` instead.
3. Tarball ships `erts-VSN/lib/crypto.a` and `erts-VSN/lib/libcrypto.a`
   (OpenSSL static).
4. The user's `CMakeLists.txt` template adds them to
   `target_link_libraries`, alongside the existing `libbeam.a`,
   `asn1rt_nif.a`, etc.
5. App's main native lib (e.g. `libpigeon.so`) ends up with crypto
   statically linked. Same shape as today's `mob_nif` and
   `asn1rt_nif`. No new shared libs in the APK / .ipa.

**Store-friendliness consequence (positive):**

- Android: same single `libpigeon.so` per ABI, just larger by ~10 MB
  (libcrypto.a embedded). Play Store has no issue with this; it's
  cleaner than shipping a separate `crypto.so` next to `libpigeon.so`.
- iOS: zero `.a` / `.so` files in the .ipa bundle. The static-link
  path matches what `app_store_plan.md` already established for
  `libbeam.a` and the rest. iOS device dev mode and App Store mode
  use the same tarball.

**App binary growth:** ~10 MB total (libcrypto.a is ~10 MB; the OTP
crypto NIF wrapper is ~750 KB; `-Wl,--gc-sections` discards unused
crypto code, bringing the realistic embedded delta to ~4-5 MB).
Within iOS App Thinning and Android App Bundle slicing budgets.

**OpenSSL license:** Apache 2.0 since 3.0. Static-linkable, no
copyleft. Apps need standard third-party-license attribution; this
will be added to the `mob_new` template once tarballs ship.

---

## Goal

Pre-built OTP tarballs (`otp-android-<hash>.tar.gz`, `otp-android-arm32-<hash>.tar.gz`,
`otp-ios-sim-<hash>.tar.gz`, `otp-ios-device-<hash>.tar.gz`) ship with:

1. A real `libcrypto`/`libssl` linked into a real `crypto.so` NIF
2. The `crypto`, `public_key`, and `ssl` OTP applications' BEAMs
3. `crypto:generate_key/2` working for `:ecdh` over `:x25519` (and the
   common curves), `crypto:crypto_one_time_aead/6-7` working for
   ChaCha20-Poly1305 and AES-GCM, `crypto:hash/2` and `crypto:mac/4`
   working for SHA-2 family, `crypto:hkdf*` working

After this lands:
- `mob_dev/lib/mob_dev/deployer.ex`'s `generate_crypto_shim/0` is no
  longer needed (the shim was a workaround, not a feature)
- Generated `ios/build.sh` template loses its inline crypto shim block
- `pigeon` boots cleanly to step 5 on both platforms
- Any future mob app can use `:crypto` for real cryptography without
  rebuilding tarballs

**Per-app overhead must stay at zero** — same `mix mob.deploy` command,
the framework now hands the user real crypto.

---

## Strategy: cross-compile OpenSSL once per target, then re-link OTP

There is no `--with-system-ssl` shortcut for cross-builds. The OTP
configure looks for `libcrypto`/`libssl` on the **host**, not the target,
so we have to point it explicitly via `--with-ssl=$PREFIX` at a
target-architecture OpenSSL install we built ourselves.

OpenSSL 3.x has the most active cross-compile support (Android NDK
targets, iphoneos targets) and is what current OTP releases match
against. Pin to the latest 3.x LTS at start-of-work; record exact
version in this doc.

### Per target: what we build

| Target | Toolchain | OpenSSL `Configure` flag | Linked into |
|---|---|---|---|
| Android arm64 | NDK r26+ `aarch64-linux-android` clang | `android-arm64 -D__ANDROID_API__=24` | `crypto.so` (dynamically loaded by BEAM) |
| Android arm32 | NDK `armv7a-linux-androideabi` clang | `android-arm -D__ANDROID_API__=24` | `crypto.so` |
| iOS sim (arm64) | `xcrun -sdk iphonesimulator clang` | `iossimulator-xcrun` | `crypto.so` (NIF dlopen still works in simulator) |
| iOS device (arm64) | `xcrun -sdk iphoneos clang` | `ios64-xcrun` | **statically** linked; iOS App Store won't accept dynamic libs |

iOS device requires extra care: `crypto.so` cannot be a dynamic library
at App Store time. The `app_store_plan.md` static-link path needs to be
extended so `crypto`'s NIF is registered via `STATIC_ERLANG_NIF` and
linked into `libbeam.a` alongside `mob_nif`. Dev mode (running from
Xcode) can keep the dynamic NIF since dev builds are not bound by store
rules.

---

## Workstream 1 — Cross-compile OpenSSL (4 targets) [in progress]

Single source repo, four build prefixes:

```
~/code/openssl/         # source tree (git clone openssl/openssl, checkout latest 3.x tag)
/tmp/openssl-android-arm64/
/tmp/openssl-android-arm32/
/tmp/openssl-ios-sim/
/tmp/openssl-ios-device/
```

Build script per target written into
`~/code/mob_dev/scripts/release/openssl_<target>.sh`. Each script:

1. Sets toolchain env (CC, CXX, AR, RANLIB, target sysroot)
2. Runs `./Configure <target> --prefix=$PREFIX no-shared no-tests no-apps -fPIC`
3. `make -j8 && make install_sw`
4. Verifies `$PREFIX/lib/libcrypto.a` and `$PREFIX/include/openssl/evp.h` exist

Doc the exact NDK version + iOS SDK version + OpenSSL tag in this file
once the first target builds clean.

**Acceptance:** all four `$PREFIX/lib/libcrypto.a` exist, each has the
expected target architecture (`file libcrypto.a` shows correct arch).

---

## Workstream 2 — Re-cross-compile OTP with `--with-ssl`

For each of the four targets, the existing OTP cross-compile in
`build_release.md` must be updated:

```diff
 ./otp_build configure \
     --xcomp-conf=./xcomp/erl-xcomp-arm64-ios.conf \
-    --without-ssl
+    --with-ssl=/tmp/openssl-ios-device \
+    --disable-dynamic-ssl-lib
```

The `--disable-dynamic-ssl-lib` is critical: OTP's default is to assume
`libcrypto` is dynamic and link `crypto.so` against it at runtime. We
want OpenSSL statically linked into `crypto.so` so the device doesn't
need a separate libcrypto.dylib/.so.

Per-target build dirs in `~/code/otp/`:
- `erts/aarch64-linux-android/` (already populated for arm64)
- `erts/armv7a-linux-androideabi/`
- `erts/aarch64-apple-iossimulator/`
- `erts/aarch64-apple-ios/` (the iOS device dir we already cross-compile)

After OTP cross-compile completes:
- `lib/crypto-<vsn>/priv/lib/<arch>/crypto.so` — the real NIF
- `lib/crypto-<vsn>/ebin/*.beam` — crypto/crypto_ec/etc BEAMs
- `lib/public_key-<vsn>/ebin/*.beam`
- `lib/ssl-<vsn>/ebin/*.beam`

For iOS device (App Store mode): also need `libcrypto.a` archive
contents addressable for the static-link build later. Capture them in
the OTP install tree so `tarball_ios_device.sh` can stage them.

**Acceptance:** for each target,
`/tmp/otp-<target>/lib/crypto-*/priv/lib/*/crypto.so` exists and is the
right architecture.

---

## Workstream 3 — Tarball staging updates

`tarball_android_arm64.sh`, `tarball_android_arm32.sh`, `tarball_ios_sim.sh`,
`tarball_ios_device.sh` each currently bundle stdlib + ERTS + asn1 NIF,
plus an in-tree `exqlite` add-on. Add to each:

```bash
# crypto + supporting apps
copy_app crypto-$CRYPTO_VSN
copy_app public_key-$PK_VSN
copy_app ssl-$SSL_VSN

# crypto NIF (priv/lib/<arch>/crypto.so)
mkdir -p "$STAGE/lib/crypto-$CRYPTO_VSN/priv/lib"
cp -R "$OTP_RELEASE/lib/crypto-$CRYPTO_VSN/priv/lib/." \
       "$STAGE/lib/crypto-$CRYPTO_VSN/priv/lib/"
verify_present "lib/crypto-$CRYPTO_VSN/priv/lib"
```

Where `$CRYPTO_VSN`, `$PK_VSN`, `$SSL_VSN` are auto-detected from the
OTP install tree (similar pattern to `EXQLITE_VSN`).

For iOS device, stage `libcrypto.a` and `libssl.a` alongside the
existing libbeam.a/libethread.a etc., for static-link builds.

**Acceptance:** each tarball includes `lib/crypto-*/priv/lib/*/crypto.so`
and the three application directories. `mob_dev`'s `valid_otp_dir?/2`
gets a new check for `lib/crypto-*/priv/lib`.

---

## Workstream 4 — Publish + downstream updates

1. `publish.sh` uploads the four new tarballs as a new GitHub release
   tagged `otp-<newhash>`. The hash auto-derives from the OTP source
   tree HEAD. If we're still on commit `73ba6e0f`, force a fresh hash
   via amend or a deliberate dummy commit so the cache key changes
   (otherwise users with cached tarballs won't see the new content).
2. `~/code/mob_dev/lib/mob_dev/otp_downloader.ex`: bump `@otp_hash` to
   the new value. One-line change.
3. `~/code/mob_dev/lib/mob_dev/deployer.ex`: in
   `generate_crypto_shim/0`, detect whether the OTP install tree
   already contains real `crypto.beam` (look for
   `lib/crypto-*/ebin/crypto.beam`). If so, skip shim install
   entirely. If not (older cached tarball), keep installing the shim
   for backward compatibility.
4. `~/code/mob_new/priv/templates/mob.new/ios/build.sh.eex`: remove
   the inline crypto-shim creation block (lines 125-143 of pigeon's
   copy). Bump `mob_new` version + rebuild archive.
5. `~/code/mob/CLAUDE.md`: drop the "Mob ships an Elixir-side crypto
   shim for HTTP-only Phoenix on-device" qualifier in the comments.
   Update `build_release.md` step 3b.0 to use `--with-ssl=...`.

**Acceptance:** a fresh `mix mob.new test_crypto && cd test_crypto &&
mix mob.install && mix mob.deploy --native` produces a working app
where `:crypto.generate_key(:ecdh, :x25519)` returns a binary keypair
without error. Pigeon boots to step 5 cleanly on both platforms.

---

## Workstream 5 — Test coverage

Tests added to `~/code/mob_dev/test/`:

1. `test/mob_dev/otp_audit_test.exs` — assert that a downloaded OTP
   runtime contains `lib/crypto-*/priv/lib` with at least one `.so`
   file. Catches regressions if a future tarball loses the crypto NIF.
2. `test/mob_dev/deployer_test.exs` — assert
   `generate_crypto_shim/0` is skipped when real crypto is present
   (mock the lib dir).
3. `test/onboarding/generator_test.exs` — fresh project's
   `ios/build.sh` does NOT contain "Creating crypto shim" string.
4. New test fixture: a minimal app that exercises
   `:crypto.generate_key(:ecdh, :x25519)` via `Mob.Test.eval/2` after
   deploy. CI gate on this so the next OTP-tarball regression is
   caught at PR time.

---

## Strategy: validate on one target before doing all four

Order of operations for the work itself:

```
1. Cross-compile OpenSSL for Android arm64 only
2. Re-cross-compile OTP arm64 with --with-ssl
3. Stage + tar a one-off Android arm64 tarball
4. Manually drop it into ~/.mob/cache/, redeploy pigeon
5. Verify pigeon boots to step 5 => ok with real x25519
6. ONLY THEN replicate to arm32 + iOS sim + iOS device
```

If something fundamental breaks (e.g. NDK API mismatch, OpenSSL doesn't
provide a symbol OTP expects), we'd rather find it on one target.

---

## Decisions (lock in once made)

1. **OpenSSL version:** TBD — pin to latest 3.x LTS. Record exact tag
   here. (3.0.x has long support; 3.3.x is current as of mid-2025.)
2. **Static vs dynamic crypto.so:** dynamic on Android (standard NIF
   pattern, no App Store rule against it) and iOS sim; static on iOS
   device for App Store mode. Dev mode iOS device builds can use
   dynamic; the static path is only for `--app-store`.
3. **`--disable-dynamic-ssl-lib`:** yes everywhere. Bundling our own
   OpenSSL statically into `crypto.so` is simpler than shipping
   separate `libcrypto.so` files alongside.
4. **Public_key + ssl apps:** include them. They're <1MB combined and
   future apps may want HTTPS clients on-device. Not just crypto.
5. **iOS App Store statics:** out of scope for this plan's first
   pass — the dev-mode tarballs ship dynamic. Static-link path is a
   follow-on once dev mode boots cleanly.

---

## Where to look first

| Question | File |
|---|---|
| What does the current crypto shim look like? | `~/code/mob_dev/lib/mob_dev/deployer.ex` lines 1140-1230 |
| How is each tarball assembled? | `~/code/mob_dev/scripts/release/tarball_<target>.sh` |
| How is OTP cross-compiled per target? | `~/code/mob_dev/build_release.md` |
| Where does the `@otp_hash` get bumped? | `~/code/mob_dev/lib/mob_dev/otp_downloader.ex` |
| What does the per-project `ios/build.sh` template look like? | `~/code/mob_new/priv/templates/mob.new/ios/build.sh.eex` (or wherever the template lives) |
| Where is the OTP source tree? | `~/code/otp` (currently at `OTP-29.0-rc2-256-g73ba6e0f92`, erts-16.3) |
