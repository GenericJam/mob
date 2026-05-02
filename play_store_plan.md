# Google Play Store Plan

Working document for the framework work to make `mix mob.republish
--android` produce Play-Store-shippable `.aab` files. Mirrors the
shape of `app_store_plan.md` (which delivered the iOS path).

**Status (2026-05-02):** Workstream 1 done — surfaced a structural gap (no Android OTP-bundling path exists). Surfaced to user before continuing W2; estimate jumped from 1-2 days to 2-3.

---

## Goal

`mix mob.republish --android` produces an `.aab` that:

1. Builds with the upload keystore signing config
2. Uploads to Google Play Publishing API v3 cleanly
3. Lands in the app's Internal testing track (default), available to
   listed internal testers within ~5-15 minutes
4. Runs identically to a `mix mob.deploy --native --android` build from
   the user's POV

**Per-app overhead must stay at zero** — same command shape, framework
does the right thing under the hood.

## Strategy: parallel to the iOS path

- **Dev mode (default)**: Gradle assembleDebug, USB sideload via adb,
  full test harness, Erlang distribution surface. **Unchanged.** This
  is what `mix mob.deploy --native --android` produces today.
- **Release mode (`--android` flag on `mix mob.release` / `publish` /
  `republish`)**: Gradle bundleRelease with upload keystore, signed
  `.aab`, uploaded to Play via Publishing API, released to a track.

## Confirmed decisions (2026-05-02)

1. **Native HTTP for the Play Publishing API**, not `fastlane supply`.
   Keeps mob_dev's deps minimal (`Req` + `JOSE` for JWT signing —
   both small, both Hex-grade). No Ruby/Bundler/fastlane runtime
   prereq for users.
2. **Per-project gitignored upload keystore** at `android/upload.keystore`.
   Easier to back up alongside the project, easier to associate with
   the right app.
3. **Internal track is the default** for `publish --android`.
   Analogous to TestFlight Internal. `--track <closed|open|production>`
   for explicit selection.
4. **`mix mob.release` gains required `--ios|--android` flag.**
   Breaking change for anyone scripting `mix mob.release` without args.
   Cleaner long-term — makes the platform asymmetry visible everywhere.
   Error message points at the flags.

## Prior art

- **`mix mob.deploy --native --android`** already builds and installs
  debug APKs on connected devices. The Gradle pipeline + JNI bridge is
  proven; release mode just needs different signing + bundle output.
- **iOS path (`app_store_plan.md`)** — same parallel structure for the
  release-pipeline / publish-API / republish-wrapper trio. Decisions
  log there is reference material for "how did we resolve X for iOS"
  questions that come up here too.
- **Google Play Publishing API v3 docs**:
  https://developers.google.com/android-publisher/api-ref/rest
- **elixir-desktop's example-app** — `github.com/elixir-desktop/desktop-example-app`
  ships Elixir apps to Play Store via exactly the asset-zip pattern
  recon identified. Their `Bridge.kt:unpackZip()` is ~30 lines; their
  `run_mix` script does `zip -9r app.zip lib/ releases/ --exclude "*.so"`.
  Pattern is proven in production; we'll mirror it.
- **`~/code/beam-android-test/BEAM-ANDROID.md`** — explicitly noted
  the asset-extraction work as TODO ("Bundle OTP files into APK
  assets, extract on first launch"). Benchmarks measure 691 ms cold
  / 331 ms warm BEAM boot on Moto G Power 5G with adb-pushed OTP.
  Asset extraction adds first-launch one-time cost; subsequent
  launches are warm.

## Workstreams

### Workstream 1 — Recon (~2 hrs)

**Goal**: understand the current Android build pipeline so the release
mode is a delta, not a rewrite.

- [ ] Read current Gradle setup in air_cart_max — what does
      `assembleDebug` produce, where does it live, what's the JNI
      build configuration look like
- [ ] Trace `mix mob.deploy --native --android` end-to-end —
      which mob_dev module drives the build, how is the APK pushed,
      how is the BEAM started
- [ ] Identify what's missing for release: signing config, bundleRelease
      target, ProGuard/R8 considerations for the embedded BEAM
- [ ] Verify the OTP runtime tree currently bundled into the APK —
      do we need an Android equivalent of the iOS strip-from-bundle
      pass, or does Gradle's R8 handle dead code differently
- [ ] Document findings before starting Workstream 2 — likely
      surfaces decision points we haven't anticipated

### Workstream 2 — Upload keystore + signing (~2 hrs)

**Goal**: app produces a signed `.aab` ready to upload to Play.

- [ ] Document the one-time keystore generation:
      `keytool -genkey -v -keystore android/upload.keystore \
       -keyalg RSA -keysize 2048 -validity 10000 -alias upload`
- [ ] Add `android/upload.keystore` + the keystore credentials file
      to `.gitignore` in the air_cart_max project
- [ ] Generate the air_cart_max upload keystore as the test case
- [ ] Add release signing config to `android/app/build.gradle`:
      reads keystore + alias + passwords from `android/keystore.properties`
      (gitignored) so the credentials aren't in the build script
- [ ] Verify `./gradlew bundleRelease` produces a signed `.aab` at
      `android/app/build/outputs/bundle/release/app-release.aab`
- [ ] Document the App Signing by Google Play setup (one-time on
      Play Console — upload your upload-key public cert; Play does
      production signing)

### Workstream 2.5 — OTP asset bundling + first-launch extractor (~half day)

**Goal**: Mob's release Android apps can extract their bundled OTP
runtime on first launch (since they can't `adb push` like dev builds).

Mirrors the elixir-desktop example-app pattern. Adds:

- [ ] Strip-from-bundle pass for the OTP tree (same as iOS — drop
      unused libs like megaco, drop standalone executables, etc.)
- [ ] `zip -9r android/app/src/main/assets/otp.zip ...` (excluding
      `.so` files; those go to `jniLibs/`)
- [ ] Copy `.so` files from OTP into
      `android/app/src/main/jniLibs/<abi>/` (mob already has this
      mechanism for ERTS helpers like `erl_child_setup`)
- [ ] Kotlin extractor in `MobBridge.kt` (or new `MobOtpExtractor.kt`):
  - [ ] On startup, check `<filesDir>/otp/.installed_version`
  - [ ] If absent or doesn't match `packageInfo.lastUpdateTime`,
        delete `<filesDir>/otp/` and extract `assets/otp.zip` into it
  - [ ] Write `lastUpdateTime` to `.installed_version`
  - [ ] Then proceed with the existing BEAM startup (which reads
        `<filesDir>/otp/`)
- [ ] mob_new template gets the extractor too — every fresh app
      ships with the asset-bundling path ready

### Workstream 3 — Build pipeline (`mix mob.release --android`) (~3 hrs)

**Goal**: `mix mob.release --android` produces
`_build/mob_release/<App>.aab` from any Mob app.

- [ ] Refactor `Mix.Tasks.Mob.Release` to require `--ios|--android`
      (breaking change; clear error message)
- [ ] Add `MobDev.Release.Android` module (sibling of the existing
      iOS-only `MobDev.Release`)
- [ ] `MobDev.Release.Android.build_aab/1`:
  - [ ] Resolves keystore path + credentials (per-project,
        `android/keystore.properties`)
  - [ ] Runs `./gradlew bundleRelease` with right env
  - [ ] Validates the output `.aab` is signed
  - [ ] Copies to `_build/mob_release/<App>.aab`
- [ ] Verify the produced `.aab` opens in `bundletool` without
      errors (locally — verifies bundle structure before upload)
- [ ] Tests (string-shape, parallel to `release_script_test.exs`):
      keystore config emitted, bundleRelease invoked, output path
      asserted

### Workstream 4 — Publish (`mix mob.publish --android`) (~3 hrs)

**Goal**: `mix mob.publish --android` uploads `.aab` to Play.

- [ ] Add deps to mob_dev: `req` (HTTP client, ~50 KB), `jose`
      (JWT signing, ~100 KB)
- [ ] `mob.exs` config block for Play credentials:

      ```elixir
      config :mob_dev,
        google_play: [
          package_name: "com.beyondagronomy.aircartmax",
          service_account_json: "~/.mob/google-play/<app>.service-account.json",
          default_track: "internal"
        ]
      ```

- [ ] `MobDev.Play.Auth` — JWT-bearer flow against
      `https://oauth2.googleapis.com/token` to get an access token
      from the service account JSON. ~30 lines.
- [ ] `MobDev.Play.Publish` — Publishing API v3 sequence:
  1. POST `/edits` → get edit ID
  2. POST `/edits/{editId}/bundles` (multipart, AAB body) → get
     versionCode of uploaded bundle
  3. PUT `/edits/{editId}/tracks/{track}` with the new versionCode
     in the release group
  4. POST `/edits/{editId}:commit` → makes it live on the track
- [ ] `Mix.Tasks.Mob.Publish` — extend to dispatch `--android` to
      the new module (currently raises "not yet implemented")
- [ ] `--track <name>` flag (`internal`/`closed`/`open`/`production`,
      default `internal`)
- [ ] Tests for auth (mock the OAuth endpoint) + the API sequence
      shape (mock the Play API)

### Workstream 5 — Republish (`mix mob.republish --android`) (~1 hr)

**Goal**: same one-shot wrapper as iOS but for Android.

- [ ] Extend `Mix.Tasks.Mob.Republish` — add the `:android` branch
- [ ] `bump_android_version_code!/1` — equivalent of
      `bump_ios_build_number!/1` but reads/writes `versionCode` in
      `android/app/build.gradle` (regex-based — gradle is more annoying
      than a plist but tractable)
- [ ] Tests: bump 1 → 2, idempotent re-runs, error if `versionCode`
      isn't a clean integer
- [ ] `--track` flag passed through to `publish --android`

### Workstream 6 — Docs (~1 hr)

**Goal**: users find the Android path and can troubleshoot it.

- [ ] Rename `publishing_to_testflight.md` →
      `publishing_to_app_stores.md` (keep redirect / hexdocs link
      working). The old name is a misnomer once Android is in.
- [ ] Add Part 1B: Android one-time setup (Play Console account,
      keystore generation, Play app record, App Signing setup,
      service account JSON, `mob.exs` config)
- [ ] Add Part 2B: per-release flow with `mix mob.republish --android`
- [ ] Add Android-specific troubleshooting entries (Play API errors,
      keystore issues, ProGuard surprises)
- [ ] Update `mob/guides/publishing.md` brief to mention both stores
- [ ] Update `mob/future_developments.md`: collapse the Android entry
      to "done" pointer

### Workstream 7 — End-to-end loop (~as long as it takes)

**Goal**: ship air_cart_max to Play Internal track from this pipeline.

- [ ] Generate keystore for air_cart_max (per workstream 2)
- [ ] Create app in Play Console (`com.beyondagronomy.aircartmax`)
- [ ] Set up App Signing by Google Play (upload the upload-key cert)
- [ ] Create Google Cloud service account, give it Play Console access
- [ ] Configure `mob.exs` with Play credentials block
- [ ] `mix mob.republish --android` → upload accepted → build appears
      in Play Console → installable via Play Store on a test device
- [ ] Verify app boots, themes work, calculator math correct,
      mailto link launches, settings persistence works

Plan for 3-5 round trips with Play API errors. Each cycle is fast
(~30s for HTTP API vs Apple's altool minutes).

## Open questions to revisit as work progresses

- **R8/ProGuard for the embedded BEAM** — does R8 strip Erlang VM
  symbols it doesn't recognize? Need to either disable R8 for release
  or add `-keep` rules. Will surface in workstream 1 recon.
- **Bundle / dynamic feature module separation** — Play wants apps
  modularized for download size. Mob ships everything in one module.
  Should be fine but Play might warn / lower the install conversion
  rate. Optimization for later.
- **Targeting requirements** — Play raised `targetSdk` requirements
  recently. Current is 34; Play's policy is "must target the previous
  major API level within a year". Verify on first upload.
- **Play Console review** — production track gets reviewed; internal
  doesn't. Verify our test path stays in internal until we explicitly
  promote.
- **Multiple ABI splits** — `.aab` lets Play deliver per-ABI APKs,
  potentially smaller installs. Need to confirm Mob's JNI builds
  cleanly for both arm64-v8a and armeabi-v7a in release mode.

## Risk register

| Risk | P | Impact | Mitigation |
|---|---|---|---|
| R8 strips/breaks Erlang VM symbols | M | release crashes immediately | Add `-keep` rules in proguard config, or disable R8 for release |
| Service account doesn't have right permissions | H (first time) | API 403 errors | Doc the exact roles needed; clear error mapping in `MobDev.Play.Auth` |
| Multipart upload of large `.aab` is finicky in Req | L | upload fails | Fall back to gen-server-style chunked upload; `req` supports streaming |
| Play Console rejects upload because bundle isn't formatted right | M | manual investigation per error | bundletool validate locally first |
| Keystore generation steps differ between Java versions | L | docs go stale | Pin a `keytool` invocation that works across JDK 11/17/21 |
| User commits keystore by mistake | M | leaks signing key | `.gitignore` template entry + scary warning in docs + `mix mob.republish --android` checks for tracked keystore at start |

## Decisions log

Capture non-obvious calls made *during* the work here, with date + reason.

- **2026-05-02 — Workstream 1 recon: Android needs an OTP-bundling
  path that doesn't exist yet.** Today's Android dev pipeline pushes
  the OTP runtime tree to `/data/data/<bundle_id>/files/otp/` via
  `adb push` (in `MobDev.NativeBuild.push_otp_release_android/5`).
  Release mode can't do that — the user installs the `.aab` from
  Play Store via the normal app install flow, no adb. So OTP must
  ship INSIDE the bundle and extract on first launch.

  iOS already has this concept — `MOB_BUNDLE_OTP` flag in
  `mob/ios/mob_beam.m` causes the iOS app to bundle OTP inside the
  `.app` and find it at runtime. There's NO Android equivalent.

  This is meaningful new work that wasn't in the original 1-2 day
  estimate. Adds:
  - **Android `assets/` packaging step** for the OTP runtime tree
    (zipped or rsync'd)
  - **First-launch extractor** in Kotlin/Java (read `assets/otp.zip`
    via `AssetManager`, extract to `filesDir/otp/`, write a version
    marker so we don't re-extract on every launch)
  - **JNI wiring** so `mob_beam.c` reads from the extracted path
    in release mode (it already reads from `<files_dir>/otp/` so
    minimal change there)
  - **Detection** that the extracted OTP is current (hash check
    against bundled version, re-extract if app updated)

  Revised estimate: 2-3 days instead of 1-2. The extra work is
  well-bounded (Android `assets/` → `filesDir` extraction is a
  textbook pattern, not novel).

- **2026-05-02 — Confirmed pattern from elixir-desktop's example-app.**
  After identifying the gap, checked `~/code/desktop` (the framework
  itself doesn't have packaging code — that's in their example-app
  on GitHub). Cloned `desktop-example-app` and confirmed the exact
  approach Mob will use:

  1. `zip -9r app.zip lib/ releases/ --exclude "*.so"` — Elixir
     release tree zipped, `.so` files excluded (they go in `jniLibs/`)
  2. Asset zip lands at `rel/android/app/src/main/assets/app.zip`
  3. `Bridge.kt:unpackZip()` (~30 lines) extracts on first launch
  4. `<filesDir>/app/done` marker contains
     `packageInfo.lastUpdateTime`; mismatch triggers re-extract
  5. After extraction, `startErlang(releaseDir, logdir)` proceeds
     as today

  Pattern is proven in production. Mob's version will be near-identical
  with minor naming changes (`otp.zip` instead of `app.zip`,
  `<filesDir>/otp/` instead of `<filesDir>/app/`). Revised estimate
  stays at 2-3 days with high confidence (no novel research needed).

## Total scope

1-2 days focused work. Roughly:
- Day 1 AM: workstreams 1 + 2 (recon + signing)
- Day 1 PM: workstream 3 (build pipeline)
- Day 2 AM: workstream 4 (publish API)
- Day 2 PM: workstreams 5 + 6 (republish + docs)
- Buffer: workstream 7 (real upload, may surface gotchas)

End state: Mob ships to Play Store. air_cart_max is the proof.
The publishing guide covers both stores and the framework is
genuinely cross-platform end-to-end.
