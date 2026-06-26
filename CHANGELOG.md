# Changelog

All notable changes to **mob** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob](https://hexdocs.pm/mob).

---

## [0.7.9] - 2026-06-26

### Fixed
- **Non-glass `:box` fill ignored `corner_radius` on iOS.** `mobBoxBackground`
  filled the solid (non-glass) background as a plain rectangle, so only the
  separately-stroked border was rounded while the fill kept square corners
  (visible on solid-color boxes; bordered light cards hid it). Clip the fill to
  the corner shape with `in: shape`, matching the glass branches. Thanks to the
  reporter who diagnosed it.

## [0.7.8] - 2026-06-25

### Added
- **`Mob.Device.open_settings/1`.** Opens an OS settings screen for the app:
  `:app` (the app details / permissions page, both platforms), `:notifications`,
  or `:exact_alarm` (Android special-access screens; iOS falls back to the app
  page). The go-to when a permission was permanently denied and the user must
  re-enable it by hand. An unknown target returns `{:error, :invalid}` without
  touching the NIF. On Android the bridge call is optional, so an app whose
  scaffolded `MobBridge.kt` predates `openSettings` no-ops instead of crashing
  (add `MobBridge.openSettings/1` to wire it up). (#50)

## [0.7.7] - 2026-06-24

### Fixed
- **Boot crash on all apps (regression in 0.7.6).** `device_orientation/0` and
  `device_lock_orientation/1` were added to `mob_nif`'s native NIF tables and
  `-export` in 0.7.6 but not to its `-nifs([])` attribute. `load_nif/2` rejects a
  library that registers a NIF not declared in `-nifs`, so `on_load` failed,
  `mob_nif` was purged, and every app crashed at boot with `{undef, {mob_nif,
  log, 1}}` on the first boot step (iOS and Android). Added the two functions to
  `-nifs([])`. A new source-level test (`test/mob/nif_declaration_test.exs`)
  asserts every NIF in the iOS/Android tables is declared in `-nifs([])`, so this
  class of mismatch — invisible to host tests, since NIFs don't load on the host —
  can't ship again. Upgrade from 0.7.6 immediately.

## [0.7.6] - 2026-06-24

### Added
- **Device orientation: detect + lock (`Mob.Device`).** New `orientation/0`
  query, an `{:mob_device, :orientation_changed, orientation}` event under the
  existing `:display` subscription category, and `lock_orientation/1` /
  `unlock_orientation/0` to force (or release) a specific orientation regardless
  of the OS auto-rotate setting. Values: `:portrait`, `:portrait_upside_down`,
  `:landscape` (either side), `:landscape_left`, `:landscape_right`. Use case: a
  screen that must be landscape (e.g. a wide keyboard) locks on enter, unlocks
  on leave.

  iOS reads the foreground window scene's interface orientation, observes
  `UIDeviceOrientationDidChangeNotification`, and drives rotation via
  `requestGeometryUpdate` (iOS 16+); the lock holds once the app shell's root
  view controller reports `mob_locked_orientation_mask()` from
  `-supportedInterfaceOrientations` (companion shell change). Android locks via
  `MobBridge.orientationLock/1` → `Activity.setRequestedOrientation`, with change
  delivery from `MainActivity.onConfigurationChanged` (companion `mob_new`
  changes). Android `orientation/0` returns the last reported orientation
  (partial, consistent with the other Android device queries).

### Fixed
- **iOS canvas now delivers finger-drag (`on_drag`) — at parity with Android.**
  The SwiftUI `MobCanvasView` rendered draw ops but attached no drag recognizer,
  so a canvas's `on_drag` handle (wired through the NIF to `node.onDrag`) was
  never invoked — continuous finger-drag was dead on iOS, while Android's
  `MobCanvas` had `detectDragGestures`. Added a canvas-scoped
  `DragGesture(minimumDistance: 0)` that calls `node.onDrag` with
  began/dragging/ended phases; the gesture's local-space location is already in
  canvas logical units (the frame is sized to the declared width/height), so no
  rescale is needed. Verified on a physical iPhone (iOS 26.5): a finger-drawing
  screen with a color picker and thickness control routes drags and renders
  strokes correctly.

---

## [0.7.4] - 2026-06-20

### Fixed
- **Tap-handle registry is now double-buffered (Android + iOS) — high-frequency
  events no longer drop during a render.** `clear_taps` reset the handle count
  to 0 and re-registered every handler in tree order, so a drag/scroll firing
  from the UI thread *while* a render rebuilt the table saw a transiently-small
  count and a half-built table and got dropped — worse the later a widget
  registered (e.g. a `Canvas` after a row of `Button`s). `register_tap` now
  builds into the inactive table while readers keep resolving the last committed
  one; `set_root` swaps them atomically under `tap_mutex`. A concurrent event
  always sees a complete table on either side of the swap. No API change.
  Verified on-device (moto, finger-drag canvas).

---

## [0.7.3] - 2026-06-19

### Removed (BREAKING)
- **`Mob.Background` is no longer in core — it moved to the opt-in
  `mob_background` plugin.** Background-execution keep-alive (iOS silent
  AVAudioEngine / Android `dataSync` foreground service) and its
  `background_keep_alive`/`background_stop` NIFs are removed from `:mob_nif`.
  Apps that call `Mob.Background.keep_alive/0` must add
  `{:mob_background, "~> 0.1"}`, enable it in `mob.exs`
  (`config :mob, :plugins, [:mob_background]`), and call
  `MobBackground.keep_alive/0` instead. Most apps never used it; the default is
  now that an app ships **no** foreground service unless it opts in — which is
  also what Google Play wants (an unused `dataSync` FGS is a policy rejection).
  Verified on Android (physical + emulator) and the iOS simulator via
  mob_plugin_demo.

---

## [0.7.2] - 2026-06-19

### Added
- **`Mob.ScreenCase`** — the blessed way to unit-test a `Mob.Screen` in-BEAM,
  with an optional device backend. Provides `mount_screen/3`,
  `render_event`/`render_info`, tree queries (`find`/`find_all`/`text`),
  `assert_renderable/2`, and `navigated_to/1`. On `:beam` it runs in
  milliseconds; the same assertions run against real hardware via `:device`.
  `navigated_to/1` returns the destination module on both backends. (#44)

---

## [0.7.1] - 2026-06-16

### Added
- **Collocated screen templates**: a `Mob.Screen` with a sibling `<name>.mob.heex`
  and no inline `render/1` gets `render/1` compiled from that template
  (`@external_resource`, so editing the template recompiles the screen). An
  inline `render/1` still wins. Opt-in and additive. (#22)
- **`Mob.Files.pick/2` type filtering**: `:types` now limits what the document
  picker offers — extension strings (`"livemd"`), MIME strings (`"application/pdf"`,
  `"text/*"`), semantic atoms (`:images`, `:video`, `:audio`, `:pdf`, `:text`),
  explicit `{:extension|:mime|:uti, value}` tuples, or `:any` (default).
  iOS filters strictly via `UTType` (extensions resolve even for unregistered
  custom types); Android SAF filters by MIME only, so `Mob.Files.accept/2` +
  `matches?/2` enforce the filter on results for consistent cross-platform
  semantics. Backward-compatible — the default `:any` preserves the previous
  "offer everything" behavior. See `decisions/2026-06-16-files-pick-type-filter.md`.

---

## [0.7.0] - 2026-06-12 — the plugin-extraction major (BREAKING)

### Added
- **Pure-Elixir composite components** (`Mob.Composite`): UI kits register tag-name expanders (the manifest `ui_components` `expand:` form, or `Mob.Composite.register/2`) and `<MyTag …/>` expands to built-in widget trees in a new FIRST render pass — fixpoint with a depth guard, crash-isolated. `on_*` props written as bare strings/atoms are auto-injected as `{screen_pid, tag}` (no more threading `self()`). Hot-pushable. See `decisions/2026-06-11-composite-expansion-pass.md`.
- **Route-bound navigation params** (`Mob.Nav.Registry.register/3` + `lookup_route/1`): a registered route can carry a params map merged under push params into `mount/3` — the enabler for data-driven plugins (mob_ash registers `/ash/post` as `{MobAsh.ListScreen, %{resource: …}}`). Screen-manifest entries take an optional `:params`.
- **Style packages, tokens-only tier** (MOB_STYLES.md implemented in part): the runtime manifest carries `styles`/`default_style`; boot applies the default style's theme (`Mob.Plugins.apply_default_style/0`). The five preset themes ship in the `mob_themes` package.
- **Boot-time plugin NIF loading** (`mob_notify_set_screen_pid` seam, `host_requirements` printing, `composites` boot registration) — the plugin-system core wiring landed across this cycle; see MOB_PLUGINS.md.

### Removed (BREAKING — each capability moves to its plugin package)
- `Mob.Camera` → `mob_camera` (the `camera_preview` node stays in core)
- `Mob.Location` → `mob_location`
- `Mob.Notify` → `mob_notify` (delivery plumbing — delegate, push-token forward, launch handoff — stays in core; pairs with the server-side `mob_push`)
- `Mob.Photos` → `mob_photos`
- `Mob.Biometric` → `mob_biometric`
- `Mob.Scanner` → `mob_scanner` (requires `mob_camera` for the `:camera` permission)
- `Mob.Bt` → `mob_bluetooth` (Wave 1)
- Themes `Obsidian`/`ObsidianGlass`/`Citrus`/`Birch`/`Material3` → `mob_themes` (light/dark/adaptive remain the neutral baseline)
No deprecation shims (see plugin_extraction_plan.md for the policy rationale). Migration: add the package dep + activate in `mob.exs`; module names change (`Mob.Camera` → `MobCamera`, `Mob.Theme.Citrus` → `MobThemes.Citrus`, …).

## [0.6.26]

### Added
- **Plugin documentation, shipped with the package.** A "Writing a Plugin" authoring guide (`guides/plugins.md`: scaffold → implement → sign → activate → deploy, per tier, with a worked-examples index) plus the manifest reference (`MOB_PLUGINS.md`) and security/trust doc (`MOB_PLUGIN_SECURITY.md`) are wired into ex_doc/HexDocs (a Plugins extras group + a `Mob.Plugins` module group). The reference now documents **cross-plugin conflict detection** (every guarded shared resource + the completeness guarantee) and the **runtime plugin manifest** + its build-time auto-regen.
- **`Mob.Plugins` runtime hardening.** Notification dispatch is crash-isolated — a handler or predicate that raises is logged and skipped instead of taking down the host screen GenServer (mirrors the lifecycle dispatcher). A malformed settings schema (missing `:default`/`:type`) logs + falls back instead of crashing reads/writes, and `register_screens` rejects a `nil` module/blank route at registration rather than deferring the error to navigation.
- **Custom fonts (app-level + plugin).** mob's `font:` prop (documented but only half-built) now works end-to-end: `mix mob.deploy --native` bundles `priv/fonts/*.ttf|otf` and plugin `assets.fonts` into the platform bundle — iOS into the `.app` + `Info.plist` `UIAppFonts` (feeding SwiftUI `Font.custom`), Android into `res/font/<normalized>` (uncompressed; the renderer loads it by resource id, fixing the previous `Typeface.create` stub that only handled system families). Visually confirmed on Android: a plugin-shipped font renders distinct from the system font.
- **Plugin tiers 3 (multi-screen) and 4 (embedded sub-app).** See `decisions/2026-06-06-plugin-tiers-3-4.md`. Both are pure-Elixir and runtime-wired off a generated runtime manifest (`priv/generated/mob_plugins.exs`, written by `mix mob.regen_plugin_manifest`) that the new `Mob.Plugins` module reads at boot. **Tier 3:** plugins ship whole `Mob.Screen` modules (static `:screens` or spec-v2 `:screens_generator` codegen run under the host-config audit), registered as navigable routes in `Mob.Nav.Registry`; plus `:migrations` (build-copied into the host migrations dir, namespaced + version-preserving, run by the host's `Ecto.Migrator`) and `:assets`. **Tier 4:** `:lifecycle` (`on_start` + supervised children + `on_resume`/`on_background` via `Mob.Plugins.Supervisor`/`Lifecycle` and `Mob.Device`), `:settings` (`Mob.Plugins.get_setting/2`/`put_setting/3` on `Mob.State`, schema-validated, with an `editor_screen`), and `:notifications` (`Mob.Plugins.dispatch_notification/1` first-match routing). Device-verified on a physical iPhone (SE) and Android (Moto G): static + generated screens register, a plugin migration creates its table on device, and tier-4 on_start / supervised worker / settings / notification routing all work. `Mob.Plugins.boot` captures the host OTP app name at compile time via `use Mob.App` (a mob release boots without `Application.start`, so `Application.get_application/1` is nil at runtime).

### Changed
- **Location fully extracted to the standalone `mob_location` plugin (Wave 2).** See `plugin_extraction_plan.md` and `decisions/2026-06-05-mob-location-extraction.md`. `Mob.Location` (`get_once`/`start`/`stop`), the iOS `CLLocationManager` NIFs + delegates, the Android `FusedLocationProviderClient` Zig NIF + `mob_deliver_location`, and the hardcoded `"location"` branch of `nif_request_permission` are removed from core (`lib/mob/location.ex`, `ios/mob_nif.m`, `android/jni/mob_nif.zig`, `src/mob_nif.erl`). `mob_location` is a cross-platform tier-1 plugin: it ships an Objective-C iOS NIF (`lang: :objc`) and an Android Zig NIF (`lang: :zig`, via `MobLocationBridge`), registers the `:location` capability through the extensible permission registry (iOS `mob_register_permission_handler`, Android `MobPermissionProvider`), and declares its Android permissions + iOS plist key + `play-services-location` + `CoreLocation` framework in its manifest (mob_dev merges these into the host at build time). **Breaking:** core no longer provides any location surface and there is intentionally no compatibility shim. Apps that used `Mob.Location.*` should add `{:mob_location, "~> 0.1"}` (or `path:`/`github:`) and call `MobLocation.*`. The same location surface was removed from the `mob_new` generated-app templates. Device-verified on a physical iPhone (SE) and Android (Moto G) both before and after the core strip — `MobLocation` round-trips real fixes through the plugin alone, and `:mob_nif.location_get_once/0` now raises `UndefinedFunctionError`.

### Fixed
- **iOS: stop capping the literal super-carrier at 10 MB.** `mob_beam.m` appended a hardcoded `-MIscs 10` after the configured flags; since allocator flags are last-wins, it silently overrode the 0.6.24 `-MIscs 128` default (and any `mob_beam_flags` override), so the literal area was always 10 MB. A large app (e.g. embedded Livebook) plus a notebook's `Mix.install` filled it and the VM aborted with `literal_alloc: Cannot allocate ...`. Removed the hardcoded cap; the `-MIscs 128` default now takes effect (iOS accepts a 128 MB reservation). Verified on a physical iPhone: `emu_args` shows a single `-MIscs 128` and `Mix.install` returns `:ok`.

## [0.6.25]

### Added
- **"Open with" — receive a file another app opens into yours.** New `Mob.Files.take_opened_document/0` returns `%{path, name, mime, size}` (or `:none`) for a file handed to the app (e.g. a notebook emailed and tapped), parallel to `Mob.Files.pick/2`'s `{:files, :picked, …}`. Call it from your root screen's `mount/3`; a file opened while already running arrives as `{:files, :opened, item}` (iOS). New NIF `take_opened_document` plus C-export `mob_set_opened_document` on both platforms (iOS `application:openURL:options:` → `mob_handle_opened_url`; Android `MainActivity` reads the ACTION_VIEW/SEND intent → `MobBridge.setOpenedDocument`). The app declares the document type (iOS `CFBundleDocumentTypes`, Android `<intent-filter>`) and forwards the open. Verified end-to-end: a `.livemd` opened into the embedded-Livebook app opens as a notebook on a physical iPhone and a physical Android (Moto G).

## [0.6.24]

### Fixed
- **iOS: enlarge the BEAM literal super-carrier to 128 MB (`-MIscs 128` default flag).** iOS can't reserve the OTP default 1 GB literal virtual area and falls back to ~10 MB. A large app such as an embedded Livebook plus a notebook's `Mix.install` fills that 10 MB and the VM aborts with `literal_alloc: Cannot allocate N bytes (of type "literal")`. The iOS native launcher's default flags now request a 128 MB literal carrier — a virtual `MAP_NORESERVE` reservation (commits physical only on use) that iOS accepts where 1 GB fails. Apps no longer need a per-app `beam_flags:` override for this. iOS-only; Android keeps its normal large carrier. A runtime `mob_beam_flags` override still wins. Verified on a physical iPhone: embedded Livebook serves and `Mix.install([{:short_uuid, "~> 0.1"}])` returns `:ok`.

## [0.6.23]

### Added
- **Element positions without a screenshot.** `element_frames/0` NIF surfaced as `Mob.Test.element_frames/1` (`%{id => {x,y,w,h}}`), `frame/2`, and `tap_id/2` (drive by id at real coordinates). Any rendered node given an `:id` reports its live on-screen frame (logical points iOS / dp Android) to a registry the agent reads over dist — a compact structured map instead of image bytes, with no accessibility activation. The renderer also sets the `:id` as the element's accessibility identifier (iOS `accessibilityIdentifier`, Android Compose `testTag`), so the same tags are visible to XCUITest/Espresso. Opt-in per element: untagged nodes cost nothing (the tracking modifier only attaches when an `:id` is present). iOS records the full element frame via a `GeometryReader` background; Android via `Modifier.onGloballyPositioned`. Verified on iOS sim, Android device, and a physical iPhone. The Android Kotlin side lives in the `mob_new` `MobBridge.kt.eex` template.
- **In-process screenshot + scroll control over dist (no adb/xcrun).** Three test-harness NIFs (`screenshot/3`, `scroll_info/1`, `scroll_to/3`) surfaced as `Mob.Test.screenshot/2`, `scroll_info/2`, `scroll_to/4`, and `screenshot_tour/3`. A remotely-connected agent gets pixels and deterministic scroll entirely over Erlang distribution — the capability Sloppy Joe and WireTap need to drive a device an agent can only reach over dist. Capture is in-process (iOS `UIGraphicsImageRenderer` + `drawViewHierarchy`; Android `PixelCopy` against the activity window). Scroll views are addressed by their `:id` prop; `scroll_info` reports `kind: :pixel` (iOS `UIScrollView`, Android `verticalScroll`) or `:index` (Android `LazyColumn`, where y is an item index and viewport is the visible-item count). Captures the app's own surface only — `FLAG_SECURE`/secure fields render blank, and a backgrounded app returns `{:error, :no_window}`. The Android Kotlin side (`screenshot`/`scrollInfo`/`scrollTo`) lives in the `mob_new` `MobBridge.kt.eex` template; existing apps pick it up on regeneration. Debug-only (iOS `#if !MOB_RELEASE`). See `decisions/2026-05-29-bridge-nif-screenshot-scroll.md`.

### Changed
- **`Mob.Bt` fully extracted to the standalone `mob_bluetooth` plugin (Wave 1 complete).** See `plugin_extraction_plan.md`. Session A moved the Elixir wrappers (`Mob.Bt`, `Mob.Bt.Hfp`, `Mob.Bt.Hid`, `Mob.Bt.Spp`) out of core; Session B now removes the native side too — the Bluetooth Zig NIF from `android/jni/mob_nif.zig` and the iOS unsupported-stubs from `ios/mob_nif.m`. `mob_bluetooth` is now a tier-1 plugin: it ships its own Zig NIF, JNI thunks, and `MobBluetoothBridge` Kotlin, and declares its Android permissions + iOS plist keys in its manifest (mob_dev merges these into the host app at build time). **Breaking:** core no longer provides any Bluetooth surface and there is intentionally no compatibility shim. Apps that used `Mob.Bt.*` should add `{:mob_bluetooth, "~> 0.1"}` (or `path:`/`github:`) and rename references to `MobBluetooth.*`. HID input and SCO PCM streaming were never implemented and are not part of the plugin (HID is platform-blocked on Android; see the plugin's docs).

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
