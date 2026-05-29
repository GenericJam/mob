# Changelog

All notable changes to **mob** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob](https://hexdocs.pm/mob).

---

## [Unreleased]

### Changed
- **`Mob.Bt` extracted to standalone `mob_bluetooth` plugin.** See `plugin_extraction_plan.md` Wave 1. Session A moved the Elixir wrappers (`Mob.Bt`, `Mob.Bt.Hfp`, `Mob.Bt.Hid`, `Mob.Bt.Spp`) out of core into a separate repo as `MobBluetooth.*`; the Zig NIF (`android/jni/mob_nif.zig`) and the iOS stubs (`ios/mob_nif.m`) stay here until Session B promotes the plugin to tier-1. Apps that used `Mob.Bt.*` should add `{:mob_bluetooth, path: "..."}` and rename their references to `MobBluetooth.*` — there is intentionally no compatibility shim.

## [0.6.22]

### Added
- **`Mob.Certs`** — load CA certificates from a PEM bundle into Erlang's `:public_key` cacert store. Android's system trust store lives behind a Java API that `:public_key.cacerts_load/0` (no-arg) can't reach, so the first TLS call from Req / Mint / Finch crashes with `no_cacerts_found` (or `FunctionClauseError` in some OTP versions). Apps bundle a PEM (conventional source: copy `castore`'s `cacerts.pem` into `priv/` at build time) and call `Mob.Certs.load_cacerts!(Application.app_dir(:my_app, "priv/cacerts.pem"))` once at boot. iOS and the Android emulator aren't affected; calling unconditionally is harmless there. Verified end-to-end on a Moto G Power 5G 2024 (Android 14): `Mix.install([{:req, "~> 0.5"}])` then `Req.get!("https://geocoding-api.open-meteo.com/v1/search?name=Vancouver")` returns `200`.
- **`mob_beam.zig` exports `MOB_NATIVE_LIB_DIR`** before BEAM start — the absolute path of the app's nativeLibraryDir, which the APK install hash makes unpredictable at compile time. Apps that bundle runtime binaries (escript, rebar3, etc.) as `lib*.so` need this to set `MIX_REBAR3` and locate the bundled escripts.
- **Optional ERTS-extras symlinks (`escript` / `erlexec` / `erl` / `beam.smp`)** in `mob_beam.zig`. Silent-skips when the lib isn't in nativeLibDir, so non-opting-in apps see no behaviour change. Apps that drop `lib<name>.so` into `android/app/src/main/jniLibs/<abi>/` get a working `BINDIR/<name>` — enough for runtime `Mix.install` of rebar3-built deps (telemetry, jose, jiffy, …) to bootstrap a fresh VM. `erl` and `erlexec` both target the same `liberlexec.so` because they are the same binary (erlexec doesn't switch on `argv[0]`).

### Changed
- **`extra_applications: [:logger, :public_key]`** — Elixir 1.19+ strips unused OTP applications from the code path; `Mob.Certs` calls `:public_key.cacerts_load/1` at runtime, so its `.beam` must be in the path even though mob doesn't *start* `:public_key` itself.

### Fixed
- **`mix.exs`** — collapsed duplicate `before_closing_body_tag/1` clauses introduced in 0.6.20. The mermaid clause's `_` catchall shadowed an older language-elixir highlighter clause, leaving it as dead code (and emitting compile warnings). The unified clause emits both scripts; the duplicate `docs/0` keyword entry was removed.

### Docs
- `common_fixes.md` — new section documenting the Android cacerts symptom (`no_cacerts_found` / `FunctionClauseError`) and the load-PEM-at-boot fix; also the bundled-OTP-extras pattern (wrapper script, rebar3 module-name derivation, `$ROOTDIR/bin/*.boot` materialization) for apps that opt into runtime rebar3.

## [0.6.21]

### Added
- **`Mob.DNS.resolve/1` now works on Android.** `nif_resolve_ipv4` (`android/jni/mob_nif.zig`) calls Bionic's `getaddrinfo` in-process and seeds `:inet_db`'s `:file` table, mirroring the iOS NIF added in #32. Physical Android devices return `:nxdomain` from BEAM's default DNS path (forking `inet_gethost` as a port program) even when the same app's in-process HTTPS stack resolves the hostname fine — the emulator masks this. Verified end-to-end on a Moto G Power 5G 2024 (Android 14): `Mob.DNS.resolve("repo.hex.pm")` returns the right IP, `:inet.getaddr/2` then succeeds via the seeded entry, and `Mix.install([{:dep, "~> ..."}])` from a notebook setup cell resolves, fetches, and compiles on-device. Bionic `addrinfo` / `sockaddr_in` / `getaddrinfo` / `freeaddrinfo` / `EAI_*` bindings added to `android/jni/mob_zig.zig`. Suspected root cause is `libnetd_client.so`'s netd routing not surviving execve; the NIF sidesteps it by running in the app's own process.

### Changed
- **`Mob.DNS` moduledoc** — dropped the "Android isn't affected" claim. Added a background-app caveat: Android App Standby blocks *all* outbound network from a backgrounded mob app (TCP-by-IP, not just DNS — surfaces as `:closed` / `:timeout` on any socket attempt). Fix is a foreground service or keep the app foregrounded; not a mob bug.

### Docs
- `common_fixes.md` — new section documenting the `:nxdomain` symptom on physical Android, the foreground-app caveat, and the fix.

## [0.6.18]

### Changed
- **`RUSTLER_NIF_LIB_PATH` → `RUSTLER_BEAM_LIBRARY_PATH`** in `mob_beam.zig`'s host setenv block. Matches the env var name filmor chose for the alternative upstream rustler PR (rusterlium/rustler#733), which is what'll land upstream instead of our #726. End-to-end tested on physical arm64 Android with filmor's branch: Mob sets the env var → rustler reads it → Rust NIF resolves and executes. Mob users on rustler 0.37 Hex release (no patch) see no change; users on the GenericJam fork OR on whatever rustler version eventually ships #733 get matching behaviour.

## [0.6.17]

### Added
- **`Mob.Audio.play_at/4`** — sample-accurate scheduled audio playback. Takes an absolute local wall-clock target (`System.system_time(:millisecond)` ms-since-epoch) and hands it to the audio *hardware* clock for firing, rather than waking the BEAM via `Process.send_after`. The hardware-clock path eliminates timer-wheel + scheduler jitter from the end-to-end sync error, leaving per-device first-sample latency (~30–80 ms, calibratable) as the dominant remaining term. iOS only in this release; Android still falls through to the existing `MediaPlayer` path (port to AAudio is pending).
- iOS: `nif_audio_play_at(Path, OptsJson, AtWallMs)` backed by a dedicated `AVAudioEngine` + `AVAudioPlayerNode`. The wall-time target is converted to an `AVAudioTime` `hostTime` via `mach_absolute_time` + `mach_timebase_info`, then handed to `-[AVAudioPlayerNode scheduleBuffer:atTime:options:completionHandler:]`. Past targets schedule ASAP. Multiple `play_at` calls accumulate on the player's timeline — use `audio_stop_playback` to flush.
- `audio_set_volume` and `audio_stop_playback` now also reach the scheduled-engine player so cross-API mixing behaves sanely.

### Use case
- Distributed orchestra / multi-device musical performance where every phone must start the same sample at the same wall-clock instant. Pair with an NTP-style server-clock-sync helper on the caller side; this API takes the converted local-clock target.

## [0.6.16]

### Added
- **`mob_beam.zig` exports `RUSTLER_NIF_LIB_PATH` before BEAM start.** Calls `dladdr(&mob_start_beam)` to discover the absolute path of the host `.so` (e.g. `lib<app>.so`) and `setenv()`s it as `RUSTLER_NIF_LIB_PATH`. Pairs with the matching upstream rustler change (rusterlium/rustler#726): rustler's `DlsymNifFiller::new()` on Android reads the env var first, falls back to its existing dladdr-self probe when unset. End result: rustler-based Rust NIFs statically linked into Mob's main `.so` now resolve `enif_*` symbols correctly on Bionic without any per-app patching. Existing rustler users on Android who *don't* run inside Mob see no change — the dladdr fallback covers them.
- **`mob_zig.zig` exposes `dladdr` + `DlInfo`** to other Zig consumers under `jni.dladdr` / `jni.DlInfo`. Hand-declared to match the libc/Bionic surface; same hand-declared FFI policy as the rest of `mob_zig.zig` (we don't use `@cImport` here).

### Notes
- The setenv runs unconditionally — even apps that don't ship a rustler NIF get the env var set. Harmless. The env var only affects rustler's own startup logic when a rustler-built NIF loads.
- Verified end-to-end on a physical arm64 Android device (moto g power 2021): host sets path → rustler reads env var → `dlopen(path, RTLD_NOW | RTLD_NOLOAD)` → `dlsym` all `enif_*` exports → Rust NIF `greet/0` executes and returns `"Hello from Rust!"` to BEAM.

## [0.6.15]

### Added
- `text_field` now accepts a `secure: true` prop. iOS renders the field
  as a SwiftUI `SecureField` (masked input) instead of the plain
  `TextField`. The prop flows through the existing renderer
  passthrough; cleartext still reaches the BEAM via `on_change` so apps
  can hash/store the value as normal. Android consumes the same prop
  via `PasswordVisualTransformation` once `mob_new`'s `MobBridge.kt.eex`
  template is updated in a companion PR — until then the prop is a
  graceful no-op on Android (renders as a regular field), no breakage.

  Reveal-toggle ("eye" button) is intentionally deferred — its
  interaction with SwiftUI focus retention requires a `ZStack`-and-opacity
  rebuild of `MobTextField` and warrants its own change.

### Fixed
- iOS: `Mob.App.start/0` now switches `:inet_db` to file-only lookup and seeds `localhost` before any user code runs — BEAM's default `:native` lookup tries to `execve` the `inet_gethost` port program, which the iOS sandbox refuses, crashing the first `Node.connect` / `:erpc.call` / `gen_tcp.connect/3` with `:badarg`. Apps no longer need to set the lookup chain themselves; `Mob.DNS.configure_pure_beam/1` still composes on top for outbound DNS. See `guides/dns_on_ios.md`.
- iOS: `Column` now honours `fill_height: true`. The `.column` case in `MobRootView` only set `maxWidth`, so a `Column` with `fill_height: true` would collapse to its children's natural height — breaking the canonical `<Column fill_width fill_height>` header/flex/footer pattern. Now sets `maxHeight: .infinity` when the prop is set and switches alignment to `.topLeading` so children anchor at the top when the column flexes. Default (no `fill_height`) behavior is unchanged.

### Docs
- Plugin system design corpus: `MOB_PLUGINS.md` (capability-plugin manifest, tiers 0-4, spec-v2 code-generated plugins), `MOB_STYLES.md` (style preset system, namespaced cherry-pick, stable per-primitive prop contract), `MOB_PLUGIN_SECURITY.md` (three-layer trust model, dev-mode escape hatches, `:acknowledge_unsafe_plugins`), `plugin_extraction_plan.md` (Phase 0 → Phase 3 + risk register + kickoff checklist). Locks scope to Elixir-first, BEAM-native, Gen-AI-enabled; parks full-language non-BEAM frontends at speculative `plugin_spec_version: 3`. Companion `agent_briefs/rustler_env_var_test.md` covers filmor's env-var-based fix in `rusterlium/rustler#726`.

## [0.6.14]

### Added
- **`:mob_nif.set_theme/1` — push resolved theme palette to native.** Lets a Compose `MaterialTheme` wrapper follow runtime `Mob.Theme.set(...)` calls instead of being baked into MainActivity at compile time. Otherwise Material 3 system chrome (NavigationBar, Button, etc.) stays at the default light scheme while the BEAM-side primitives switch to whatever theme is active — a visible mismatch when an app uses Obsidian / ObsidianGlass.
- **`Mob.Theme.resolved_palette/1`** — exposes the "semantic token → theme map → palette → ARGB int" resolution path that the renderer uses internally. The native side gets concrete integers it can hand to `Color(...)` directly.

### Notes
- iOS implements the NIF as a no-op for symmetry — SwiftUI in `MobRootView.swift` renders every surface via mob primitives with explicit color props, so there's no system chrome that needs the push.
- The Android `MobBridge.setTheme(String)` Java hook is looked up via `cacheOptional`, so older templates that predate this load fine; the NIF just returns `:ok` without dispatching when the method isn't on the bridge.
- The mob_new generator templates that wire `MaterialTheme` ↔ `setTheme` in newly-generated apps will follow in a separate release; existing apps adopt manually (a `MutableState` in MobBridge.kt + `MaterialTheme(colorScheme = …)` wrap in MainActivity.kt).

## [0.6.13]

### Changed
- **Liquid Glass uses `Glass.clear` instead of `Glass.regular`.** On dark surfaces with little behind a card to refract, `.regular` reads as a frosted plate rather than glass. `.clear` is the right variant for the floating-card look the theme is meant to evoke — what's beneath shows through, the card looks like it's hovering. Only affects iOS 26+ (the `.ultraThinMaterial` fallback for older iOS is unchanged).

## [0.6.12]

### Added
- **`Mob.Theme` — `glass` flag for translucent surfaces.** New `glass: false` field on the theme struct. When set, `Mob.Renderer` tags every `Box` node that has a `background:` with `glass: true`, and the iOS side swaps the solid fill for `.glassEffect(.regular, in: shape)` on iOS 26+ (real Liquid Glass) or `.ultraThinMaterial` on iOS 17–25 (closest fallback that ships in older SDKs). Other nodes pass through untouched. Opt in via a preset or by passing `glass: true` to `Mob.Theme.build/1`.
- **`Mob.Theme.ObsidianGlass`** — Obsidian palette + `glass: true` for the common "make the whole app glassy" case. Switch at runtime with `Mob.Theme.set(Mob.Theme.ObsidianGlass)`; revert with `Mob.Theme.set(Mob.Theme.Obsidian)`.
- **`Mob.Theme.flags_map/1`** — companion to `color_map/1` / `spacing_map/1` / `radius_map/1`. Returns `%{glass: bool}` for now; future flag-style toggles will land here.

### Notes
- Android receives the flag but ignores it for now — Compose Material 3 doesn't ship a first-class glassy surface yet; boxes fall back to solid. Compose-side support is a follow-up.

## [0.6.11]

### Fixed
- **`~MOB` sigil no longer double-encodes non-ASCII bytes in template source.** The NimbleParsec parser used `ascii_string/2` for string attribute values (`text="..."`) and brace content (`text={...}`); its `integer`-typed body re-encoded each source byte ≥128 as a Latin-1 codepoint then UTF-8. Net effect: `–` (E2 80 93) emerged as `Â`+pad+`O` (C3 A2 C2 80 C2 93) — mojibake on screen. Swapped both call sites to `utf8_string/2`, which matches by codepoint and round-trips multi-byte sequences (em-dash, en-dash, middle dot, smart quotes, accents, emoji) byte-for-byte. Workaround that's now unnecessary: binding the non-ASCII string to a variable outside the sigil and referencing it via `text={var}`.

## [0.6.10]

### Added
- **iOS BEAM startup honours `MOB_NODE_SUFFIX` env var.** The simulator branch already auto-derived a unique node-name suffix from `SIMULATOR_UDID` so concurrent sims didn't collide in Mac's EPMD, but there was no manual override path — the Android-side `MOB_NODE_SUFFIX` convention was iOS-blind. Now both branches (simulator + physical device) read `MOB_NODE_SUFFIX` with priority: explicit env → SIMULATOR_UDID-derived (sim only) → none. Pairs with `mob_dev 0.5.10`'s `mix mob.deploy --node-suffix X` flag (forwarded to simctl via the `SIMCTL_CHILD_*` mechanism).
- Resolves the `Protocol 'inet_tcp': register/listen error: no_reg_reply_from_epmd` symptom seen when running multiple iOS sims of the same app concurrently for visual-comparison work (e.g. cross-platform theme parity).

## [0.6.9]

### Fixed
- **CI pipeline unblocked.** The 0.6.8 push failed two CI gates and never
  reached Hex; this release ships the same code with the gates green:
  - `android/jni/mob_beam.h` reformatted to satisfy `xcrun clang-format
    --dry-run -Werror` (the camera-frame delivery declaration was split
    across three lines in a style clang-format wanted on two).
  - `decimal` bumped 2.4.0 → 3.1.0 (transitive via `ecto_sqlite3` /
    `jason`) to clear advisory **GHSA-rhv4-8758-jx7v** — unbounded
    exponent in `Decimal.new/1` enables an unauthenticated DoS, affects
    `< 3.0.0`. `jason` bumped 1.4.4 → 1.4.5 since older Jason capped
    `decimal` to `~> 1.0 or ~> 2.0`.

No source-level changes since 0.6.8 — same `Mob.Camera.start_frame_stream/2`
Android implementation and `Mob.Canvas` viewport docs, now actually on Hex.

## [0.6.8]

### Added
- **`Mob.Camera.start_frame_stream/2` now works on Android.** The
  Camera2 + CameraX `ImageAnalysis` use case is wired through to BEAM
  as `{:camera, :frame, %{bytes, width, height, format, timestamp_ms,
  dropped}}` messages. Previously this NIF returned `:unsupported` on
  Android — iOS-only. The Android implementation supports the same
  `format: :rgb_f32` the iOS side does (`:bgra_u8` planned for a
  follow-up).
- **`Mob.Canvas` moduledoc** documents the viewport-scaling contract:
  the `width`/`height` props are logical viewport units, NOT pixels.
  The renderer scales draw-op coordinates against the actual on-screen
  pixel size. New tests in `test/mob/canvas_test.exs` pin the
  contract so future readers don't regress to interpreting them as
  raw pixels.

### Notes
- Combined with `mob_dev 0.5.9`'s `mix mob.enable tflite` and the
  `nx_tflite_mob 0.0.3` Hex package, the cross-platform live YOLO
  demo (`mob_yolo_demo`) now runs end-to-end with only Hex deps.
  Measured perf: 24 ms iPhone SE A15 via Core ML → ANE; 75–117 ms
  Moto G Power 5G (Dimensity / BXM-8-256) via NNAPI / `mtk-gpu_shim`.
## [0.6.7]

### Added
- `guides/mobile_surface_matrix.md` — comprehensive audit of mob's mobile capability surface vs. React Native + Expo SDK reference. Tables across UI components, gestures/input, device/system, storage, camera/audio, connectivity, sensors, location, notifications, background tasks, auth/payment, ML/Vision, maps, accessibility, iOS-only, Android-only, plus an "architecturally not present" section. Per-row status (✅ / 🟡 / ❌ / ⛔) with iOS + Android indicators. Hand-maintained from inspection of `lib/mob/` and `src/mob_nif.erl`. Sets realistic expectations and surfaces plugin candidates.
- README link + hexdocs entry so the matrix is discoverable for new users.
- `RELEASE.md` "Tests + docs for new functionality" section now includes a `mix docs` preview step and clarifies that hexdocs publishing is automatic via `mix hex.publish` (rides along from the previously-unreleased doc improvement).
- `MOB_PLUGINS.md` — plugin manifest schema spec covering five plugin tiers (pure Elixir helper through embedded sub-app), worked examples per tier, install + activation flow, schema reference, validation rules, hot-push compatibility table, plugin_spec_version forward-compat. References from the matrix's ❌ rows as plugin candidates.

## [0.6.6]

### Added
- `RELEASE.md` — canonical release-process documentation covering the
  mix.exs-driven trigger model, the patch-bump-default-with-mandatory-
  permission rule, CHANGELOG conventions, when a bump is warranted (new
  functionality, bug fixes, doc improvements, dep bumps) vs. when it
  isn't (CI tweaks, hook changes, internal refactors), the
  tests-and-docs-with-new-functionality non-negotiables, and the
  per-step idempotency of `release.yml`. Linked from `mob_dev` and
  `mob_new` CLAUDE.md by URL so the canonical process is one file.
- `.githooks/pre-push` — committed pre-push hook that runs the cheap
  preflight (format + credo + warnings-as-errors) on every push and
  the full release preflight (test suite + `mob.security_scan` where
  present) only when `mix.exs` changed. Activate per-clone with
  `git config core.hooksPath .githooks`.
- `CLAUDE.md` "Release flow" section linking to the new docs.

## [0.6.5]

### Fixed
- HexDocs source links pointed at the non-existent `main` branch — corrected to `master` so each `</>` glyph next to a heading now opens the actual source file in the GitHub repo.
- `mob_nif.zig` called the variadic `enif_make_list/2` (not exposed in `mob_erts.zig`) from the BT paired-list finisher; the Android arm64 build failed at link. Switched to the non-variadic `enif_make_list_from_array(env, &empty, 0)`.

### Added
- `.github/workflows/test.yml` — runs `mix test`, `mix format --check-formatted`, `mix credo --strict`, `mix erlfmt --check src/`, `xcrun clang-format`, `swiftlint`, and `mix deps.audit` on push to master and on every PR.
- `.github/workflows/release.yml` — on tag push, creates a GitHub Release whose body is the matching `## [X.Y.Z]` section from this changelog (falls back to auto-generated commit notes if the tag has no section).
- `PLAN.md` — three-layer CI + integration-test plan covering the gap between unit tests and on-device verification.

## [0.6.4]

### Added
- `Mob.GpuView` / `Mob.UI.gpu_view/1` — Metal fragment-shader surface on iOS. Host owns the vertex shader (full-screen quad with `v_uv`); user supplies an MSL fragment shader plus a list of uniforms packed at natural alignment into fragment-buffer slot 0. SwiftUI `MobGpuView` wraps an `MTKView` with a hash-keyed shader cache and a translucent red overlay for compile errors. iOS-only in this release; the Android GLES 3.0 backend ships in mob_new 0.3.1.
- `<GpuView>` tag whitelisted for both `priv/tags/ios.txt` and `priv/tags/android.txt`.

## [0.6.3]

### Fixed
- iOS camera sensor delivered frames in landscape-right by default — `Mob.Camera.start_frame_stream/2` was feeding 90°-rotated pixels to ML models, dropping classification accuracy enough that a jar appeared as "laptop 24%" instead of "cup 96%". `AVCaptureConnection.videoRotationAngle = 90` (iOS 17+) / `videoOrientation = .portrait` (older) is now set on both the preview layer and the data-output connection, so what the user sees and what the model sees are the same upright frame.

## [0.6.2]

### Added
- `Mob.Camera.start_frame_stream/2` and `stop_frame_stream/1` — push-driven per-frame delivery as `{:camera, :frame, %{bytes, width, height, format, timestamp_ms, dropped}}`. Defaults to 640×640 `rgb_f32` for direct Nx hand-off; caller-overridable width/height/format/facing and a software `throttle_ms` gate.

### Changed
- iOS camera now uses a single shared `AVCaptureSession` for preview and frame stream. The previous two-session design silently dropped frames because iOS allows only one active session per physical camera.

## [0.6.1] and earlier

Earlier releases predate this changelog; consult the [tag list](https://github.com/genericjam/mob/tags) and the per-tag commit messages for history.
