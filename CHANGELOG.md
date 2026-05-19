# Changelog

All notable changes to **mob** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob](https://hexdocs.pm/mob).

---

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
