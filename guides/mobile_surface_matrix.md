# Mobile surface matrix

What Mob covers — what's solid, what's partial, what's missing. Use
this to set realistic expectations before starting an app, and to
spot gaps worth filling (either in mob core, in a plugin, or by
declaring out-of-scope).

The reference surface is the union of **React Native core**,
**Expo SDK modules**, and platform-native capabilities both ecosystems
have converged on as "what mobile apps need." Many missing items are
**pluggable** — see [MOB_PLUGINS.md](../MOB_PLUGINS.md) for the
manifest spec.

This doc is hand-maintained from inspection of `lib/mob/` and
`src/mob_nif.erl`. If you add a capability, update the matching row.

## Legend

| | |
|--|--|
| ✅ | Fully present — public Elixir API, both iOS + Android (unless noted) |
| 🟡 | Partial — works but limited (single platform, narrow API, or known caveats) |
| ❌ | Missing — could be a plugin or future core addition |
| ⛔ | Out of scope — requires separate deployment target (widgets, Watch app), or fundamentally incompatible with Mob's architecture |

Per-platform columns: `✓` = supported, `—` = not supported, `n/a` = not applicable on that platform.

A ✅ capability may live in **core** or in a **first-party plugin**
(0.7.0 extracted camera, photos, location, notifications, biometrics,
scanning, and Bluetooth into `mob_*` capability packages). The Notes
column names the supplying plugin; rows without one are core. Plugins
activate with the dep + `config :mob, :plugins, [...]` in `mob.exs` —
see the [Plugins guide](plugins.md).

---

## UI components (render tree)

Elements you can use inside `~MOB`. The set is intentionally small
and orthogonal — composition over a fat component library.

| Component | Status | iOS | Android | Notes |
|--|--|--|--|--|
| `<Box>` | ✅ | ✓ | ✓ | Container with align, padding, background, corner radius, border |
| `<Column>`, `<Row>` | ✅ | ✓ | ✓ | Flex layouts |
| `<Text>` | ✅ | ✓ | ✓ | Font, color, size, weight, align, line height, letter spacing |
| `<Button>` | ✅ | ✓ | ✓ | Tap handler, text, background, fill width |
| `<Image>` | ✅ | ✓ | ✓ | Local + remote (Coil on Android, AsyncImage on iOS) |
| `<TextField>` | ✅ | ✓ | ✓ | Keyboard type, return key, placeholder, change events |
| `<Toggle>` | ✅ | ✓ | ✓ | Boolean switch |
| `<Slider>` | ✅ | ✓ | ✓ | Min/max/value, change events |
| `<Progress>` | ✅ | ✓ | ✓ | Linear + circular |
| `<Divider>` | ✅ | ✓ | ✓ | Horizontal line separator |
| `<Spacer>` | ✅ | ✓ | ✓ | Layout filler |
| `<Scroll>` | ✅ | ✓ | ✓ | Vertical or horizontal, scroll observation on iOS 18+ |
| `<List>` | ✅ | ✓ | ✓ | Vertical / horizontal stack with selection |
| `<LazyList>` | ✅ | ✓ | ✓ | Virtualised long-list with on_end_reached pagination |
| `<TabBar>` | ✅ | ✓ | ✓ | Bottom tab bar (Material 3 NavigationBar on Android, SwiftUI Tab on iOS) |
| `<WebView>` | ✅ | ✓ | ✓ | Inline web view, JS bridge, navigation control |
| `<CameraPreview>` | ✅ | ✓ | ✓ | Live preview with frame stream |
| `<Video>` | 🟡 | ✓ | 🟡 | Android: ExoPlayer integration pending |
| `<GpuView>` | ✅ | ✓ | ✓ | Metal (iOS) / GLES 3.0 (Android) fragment shader surface |
| Custom views via `<NativeView>` | ✅ | ✓ | ✓ | Register a plugin-defined render-tree node type |
| Date / Time / Color pickers | ❌ | — | — | Plugin candidate |
| `<SearchBar>` | ❌ | — | — | Native search bar (UISearchBar / SearchBar). Plugin candidate |
| `<DatePicker>` | ❌ | — | — | Plugin candidate |
| `<Modal>` (sheet presentation) | 🟡 | 🟡 | 🟡 | Programmatic alerts + action sheets exist; full sheet-style modal is plugin territory |
| Pull-to-refresh | ❌ | — | — | Missing; commonly requested. Plugin candidate |
| Bottom sheets | ❌ | — | — | Plugin candidate |
| Drawer navigation | ❌ | — | — | Plugin candidate; mob's nav model is stack-based today |

## Touch, gesture, input

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Tap / double-tap / long-press | ✅ | ✓ | ✓ | `on_tap`, `on_double_tap`, `on_long_press` props |
| Swipe (l/r/u/d) | ✅ | ✓ | ✓ | `on_swipe_left`, etc. |
| Pan / drag gesture | 🟡 | 🟡 | 🟡 | Tap-based; full pan-responder system (like react-native-gesture-handler) is missing |
| Pinch / zoom | ❌ | — | — | Plugin candidate; common for image/map views |
| Rotation gesture | ❌ | — | — | Plugin candidate |
| Hardware keyboard events | ❌ | — | — | `key_press/1` exists for the test harness but not as a user-facing API |
| Keyboard show/hide events | ❌ | — | — | Missing; commonly needed for keyboard-aware layouts |
| `<KeyboardAvoidingView>` equivalent | ❌ | — | — | Plugin / core candidate |
| Apple Pencil / stylus events | ❌ | — | n/a | Plugin territory |
| 3D Touch / Force Touch | ❌ | — | n/a | Deprecated by Apple; low priority |
| Drag and drop (cross-app) | ❌ | — | — | Plugin candidate |
| Haptic feedback | ✅ | ✓ | ✓ | `Mob.Haptic.trigger/2` |

## Device + system info

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Platform detection | ✅ | ✓ | ✓ | `Mob.Device.platform/0` returns `:ios` or `:android` |
| OS version | ✅ | ✓ | ✓ | `Mob.Device.os_version/0` |
| Device model | ✅ | ✓ | ✓ | `Mob.Device.model/0` |
| Foreground / background state | ✅ | ✓ | ✓ | `Mob.Device.foreground?/0` + `{:device, :foreground/:background, ...}` events |
| Battery level + state | ✅ | ✓ | ✓ | `Mob.Device.battery_level/0`, `battery_state/0` |
| Thermal state | ✅ | ✓ | ✓ | `Mob.Device.thermal_state/0` |
| Low-power mode | ✅ | ✓ | ✓ | `Mob.Device.low_power_mode?/0` |
| Color scheme (light/dark) | ✅ | ✓ | ✓ | `Mob.Theme.color_scheme/0` + `Mob.Theme.Adaptive` (auto-watch) |
| Safe area insets | ✅ | ✓ | ✓ | `Mob.Device.safe_area/0` |
| Screen dimensions / pixel ratio | ✅ | ✓ | ✓ | `Mob.Device.screen_info/0` |
| Locale / language | 🟡 | 🟡 | 🟡 | Derivable from system; no first-class API |
| Time zone | 🟡 | 🟡 | 🟡 | Use Erlang's `:calendar` directly |
| Network info (cell vs wifi, type) | ❌ | — | — | Plugin candidate (NetInfo equivalent) |
| Network reachability | ❌ | — | — | Plugin candidate |
| Screen brightness | ❌ | — | — | Plugin candidate |
| Screen orientation lock | ❌ | — | — | Plugin candidate |
| Idle timer / screen wake | ❌ | — | — | Plugin candidate |
| Exit app | ✅ | n/a | ✓ | Android only; iOS forbids programmatic exit |

## Storage

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Key-value store | ✅ | ✓ | ✓ | `Mob.Storage` with typed schemas, namespacing |
| Files API | ✅ | ✓ | ✓ | `Mob.Files`, plus `Mob.Storage.dir/1` for app-private paths |
| External files dir (Android) | ✅ | n/a | ✓ | `storage_external_files_dir/1` |
| Save to photo library | ✅ | ✓ | ✓ | `Mob.Storage.save_to_photo_library/1` + Android MediaStore equivalent |
| SQLite | ✅ | ✓ | ✓ | Via `:ecto_sqlite3` + bundled `libsqlite3_nif.so` |
| Keychain / Keystore | ❌ | — | — | Plugin candidate (standalone API beyond biometric) |
| Secure-storage / encrypted-storage | ❌ | — | — | Plugin candidate |

## Camera + microphone

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Capture photo | ✅ | ✓ | ✓ | `MobCamera.capture_photo/2` (`mob_camera` plugin) |
| Capture video | ✅ | ✓ | ✓ | `MobCamera.capture_video/2` (`mob_camera` plugin) |
| Live preview | ✅ | ✓ | ✓ | `<CameraPreview>` component (core; session API in `mob_camera`) |
| Per-frame stream | ✅ | ✓ | ✓ | `MobCamera.start_frame_stream/2` (`mob_camera` plugin) — pushes RGBA frames to `handle_info` |
| Photo library picker | ✅ | ✓ | ✓ | `MobPhotos.pick/2` (`mob_photos` plugin) |
| Audio recording | ✅ | ✓ | ✓ | `Mob.Audio.start_recording/2` |
| Audio playback | ✅ | ✓ | ✓ | `Mob.Audio.play/3`, stop, volume |
| Text-to-speech | ✅ | ✓ | ✓ | `Mob.Speech.speak/3` + `stop_speaking/1` (AVSpeechSynthesizer / TextToSpeech) |
| Speech recognition | ❌ | — | — | Plugin candidate (SFSpeechRecognizer / SpeechRecognizer) |
| Voice activity detection | ❌ | — | — | Plugin candidate |
| Audio effects (reverb, EQ) | ❌ | — | — | Plugin candidate |
| Camera zoom / focus / exposure | 🟡 | 🟡 | 🟡 | Basic capture works; fine-grained control missing |

## Connectivity

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Bluetooth Classic | ✅ | n/a | ✓ | `MobBluetooth` plugin (extracted; Hfp / Spp / Hid sub-modules) |
| Bluetooth Low Energy (BLE) | ❌ | — | — | Plugin candidate — common request |
| NFC | ❌ | — | — | Plugin candidate (Core NFC / Android NFC) |
| WiFi info / scanning | ❌ | — | — | Plugin candidate; OS restrictions apply |
| USB host | ✅ | n/a | ✓ | `Mob.VendorUsb` — bulk read/write, custom devices |
| WebSocket client | 🟡 | n/a | n/a | Use Elixir libs directly (e.g. `:gun`) |
| HTTP client | 🟡 | n/a | n/a | Use Elixir libs (`:req`, `:finch`) |
| File upload progress | ❌ | — | — | Plugin candidate |
| Background download/upload | ❌ | — | — | Plugin candidate |
| mDNS / Bonjour | ❌ | — | — | Plugin candidate |
| Sockets (raw TCP/UDP) | 🟡 | n/a | n/a | Use Erlang's `:gen_tcp`/`:gen_udp` |
| Mob.Dist (BEAM clustering) | ✅ | ✓ | ✓ | Hot-push, device → desktop connection |

## Sensors

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Accelerometer | ✅ | ✓ | ✓ | `Mob.Motion.start(:accelerometer, ...)` |
| Gyroscope | ✅ | ✓ | ✓ | `Mob.Motion.start(:gyro, ...)` |
| Magnetometer | ❌ | — | — | Plugin candidate; `CMMotionManager` / `Sensor.TYPE_MAGNETIC_FIELD` |
| Barometer | ❌ | — | — | Plugin candidate |
| Proximity | ❌ | — | — | Plugin candidate |
| Ambient light | ❌ | — | — | Plugin candidate |
| Pedometer / step counter | ❌ | — | — | Plugin candidate |
| Compass / heading | ❌ | — | — | Plugin candidate |

## Location

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| One-shot location | ✅ | ✓ | ✓ | `MobLocation.get_once/1` (`mob_location` plugin) |
| Continuous updates | ✅ | ✓ | ✓ | `MobLocation.start/2`, stop (`mob_location` plugin) |
| Background location | 🟡 | 🟡 | 🟡 | Mob's foreground-service keep-alive lets updates continue while backgrounded; not a true background-location API |
| Geofencing | ❌ | — | — | Plugin candidate (`CLCircularRegion` / `Geofencing API`) |
| Significant-change updates | ❌ | — | — | Plugin candidate (iOS) |
| Mock-location detection | ❌ | — | — | Plugin candidate |
| Reverse geocoding | ❌ | — | — | Use third-party API for now (e.g. Mapbox) |

## Notifications

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Local notification scheduling | ✅ | ✓ | ✓ | `MobNotify.schedule/2`, cancel (`mob_notify` plugin) |
| Push notification registration | ✅ | ✓ | ✓ | `MobNotify.register_push/1` (`mob_notify` plugin) → token to `handle_info` |
| Push delivery via APNs / FCM | ✅ | ✓ | ✓ | Via `mob_push` Hex package |
| Notification tap handling | ✅ | ✓ | ✓ | Foreground + background + cold-start (`take_launch_notification/0`) |
| Notification actions (buttons) | ❌ | — | — | Plugin / core candidate |
| Critical / time-sensitive flags (iOS) | ❌ | — | n/a | Plugin candidate |
| Notification grouping / threading | ❌ | — | — | Plugin candidate |
| Badge management | 🟡 | 🟡 | 🟡 | Basic only |

## Background tasks

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Foreground service / keep-alive | ✅ | ✓ | ✓ | `Mob.Background.keep_alive/0` |
| Background fetch (silent periodic) | ❌ | — | — | Plugin candidate (iOS Background Tasks framework / Android WorkManager) |
| Silent push handling | 🟡 | 🟡 | 🟡 | Push arrives but no dedicated "wake-and-handle-then-suspend" lifecycle |
| Background URL session | ❌ | — | — | Plugin candidate |
| Scheduled jobs (periodic / one-shot) | ❌ | — | — | Plugin candidate (WorkManager equivalent) |

## Auth + payment

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Biometric auth (Face ID / fingerprint) | ✅ | ✓ | ✓ | `MobBiometric.authenticate/2` (`mob_biometric` plugin) |
| Apple Sign-In | ❌ | — | n/a | Plugin candidate (common requirement for App Store) |
| Google Sign-In | ❌ | — | — | Plugin candidate |
| Sign in with X / Facebook / etc. | ❌ | — | — | Plugin candidate |
| OAuth flow helpers | ❌ | — | — | Plugin candidate; can mostly be done from Elixir |
| In-app purchase (StoreKit / Play Billing) | ❌ | — | — | Plugin candidate; sensitive — needs receipt validation |
| Apple Pay | ❌ | — | n/a | Plugin candidate |
| Google Pay | ❌ | — | — | Plugin candidate |
| Passkeys / WebAuthn | ❌ | — | — | Plugin candidate |

## ML / Vision

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| QR / barcode scanning | ✅ | ✓ | ✓ | `MobScanner.scan/2` (`mob_scanner` plugin; activate `mob_camera` too — it owns `:camera`) — full-screen scanner with format filtering |
| TFLite model inference | ✅ | ✓ | ✓ | Via `mix mob.enable tflite` (mob_dev 0.5.7+) — NNAPI/MTK on Android, Core ML delegate on iOS |
| Nx-based inference | 🟡 | 🟡 | 🟡 | Via `nx_eigen` exploration; not formalised |
| Apple Vision framework wrappers | ❌ | — | n/a | Plugin candidate (text recognition, face detection, image classification) |
| Apple Foundation Models (LLM) | ❌ | — | n/a | Plugin in flight — see mob PR #8 (DRAFT) |
| MLKit wrappers (Android) | 🟡 | n/a | 🟡 | Barcode scanning uses it under the hood; other models (text, face, pose) are plugin territory |
| OCR (text recognition) | ❌ | — | — | Plugin candidate |
| Face detection | ❌ | — | — | Plugin candidate |
| Pose detection | ❌ | — | — | Plugin candidate |
| Speech-to-text | ❌ | — | — | Plugin candidate |
| Translation | ❌ | — | — | Plugin candidate |
| Smart Reply | ❌ | — | — | Plugin candidate |

## Maps

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Native map view | ❌ | — | — | Plugin candidate (Apple Maps / Google Maps) |
| Annotations / markers | ❌ | — | — | Plugin candidate |
| Polylines / polygons | ❌ | — | — | Plugin candidate |
| User location display | ❌ | — | — | Plugin candidate |
| Map tile providers (Mapbox, etc.) | ❌ | — | — | Plugin candidate |

## System integration

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Clipboard | ✅ | ✓ | ✓ | `Mob.Clipboard.put/1`, `get/0` |
| Open URL (deep linking, browser) | ✅ | ✓ | ✓ | `Mob.Device.open_url/1` — picks browser, mail, tel, etc. |
| Share sheet (text) | ✅ | ✓ | ✓ | `Mob.Share.text/1` |
| Share sheet (image / file) | ❌ | — | — | Plugin candidate |
| Document picker | ✅ | ✓ | ✓ | `Mob.Files.pick/1` |
| Action sheet (iOS-style menu) | ✅ | ✓ | ✓ | `action_sheet_show/2` via Mob.Alert |
| Toast (Android-style) | ✅ | ✓ | ✓ | `toast_show/2` — implemented on both platforms |
| Alert dialog | ✅ | ✓ | ✓ | `Mob.Alert.alert/2` |
| Vibration patterns | ✅ | ✓ | ✓ | Via `Mob.Haptic` |
| App settings page (open) | ❌ | — | — | Plugin candidate |
| Calendar events | ❌ | — | — | Plugin candidate |
| Contacts | ❌ | — | — | Plugin candidate |
| Reminders (iOS) | ❌ | — | n/a | Plugin candidate |
| Permissions facade | ✅ | ✓ | ✓ | `Mob.Permissions.request/2` for camera, microphone, photos, location, notifications |

## Accessibility

| Capability | Status | iOS | Android | Notes |
|--|--|--|--|--|
| Accessibility labels / hints | 🟡 | 🟡 | 🟡 | Some component props expose this; not uniform across all components |
| Screen reader announcements (imperative) | ❌ | — | — | Plugin / core candidate |
| Focus management (programmatic) | ❌ | — | — | Plugin / core candidate |
| Reduce-motion preference | ❌ | — | — | Plugin candidate |
| Bold-text preference | ❌ | — | — | Plugin candidate |
| Dynamic type / font scaling | 🟡 | 🟡 | 🟡 | iOS automatic via system size; explicit override needed |
| RTL support | 🟡 | 🟡 | 🟡 | Layout-engine level; no explicit `I18nManager` equivalent |
| Accessibility test inspection | ✅ | ✓ | ✓ | `Mob.Test` reads the AX tree for assertion-based UI testing |

## iOS-only platform features

| Capability | Status | Notes |
|--|--|--|
| Live Activities / Dynamic Island | ⛔ | Requires Widget Extension target — separate from main app; not a Mob template today |
| Widgets (home + lock screen) | ⛔ | Same — Widget Extension target |
| App Clips | ⛔ | App Clip target; not in Mob templates |
| Watch app companion | ⛔ | WatchKit target; not in Mob templates |
| Share extensions | ⛔ | Share Extension target; not in Mob templates |
| Today extensions (deprecated by Apple) | ⛔ | — |
| Background App Refresh | ❌ | Plugin candidate |
| Apple Pencil events | ❌ | Plugin candidate |
| Multi-window (iPad) | 🟡 | App runs but no first-class multi-scene API |
| Split View / Slide Over | 🟡 | Same as multi-window |
| Picture in Picture (video) | ❌ | Plugin candidate |
| Universal Links / Custom URL Scheme | 🟡 | Open URL works; route registration is per-app, no unified API |
| Handoff / NSUserActivity | ❌ | Plugin candidate |
| Spotlight indexing | ❌ | Plugin candidate |
| App Shortcuts (Siri integration) | ❌ | Plugin candidate |

## Android-only platform features

| Capability | Status | Notes |
|--|--|--|
| Home screen widgets | ⛔ | AppWidgetProvider — separate component, not in Mob templates |
| Quick Settings tiles | ⛔ | TileService — separate component |
| App Shortcuts (long-press launcher) | ❌ | Plugin candidate |
| Picture in Picture | ❌ | Plugin candidate |
| Multi-window | ✅ | Works via resizable activity flag |
| Split-screen | ✅ | Works via resizable activity flag |
| Foldable / large-screen support | 🟡 | Layout adapts; no first-class foldable APIs |
| Auto Backup | ✅ | Honored by default per AndroidManifest |
| Doze mode handling | ❌ | Plugin candidate (alarm/wake-up scheduling) |
| Direct Share | ❌ | Plugin candidate |
| Notification channels (configurable) | 🟡 | Default channel works; per-app multi-channel API is partial |

## Architecturally not present (and probably shouldn't be)

| Item | Why |
|--|--|
| JavaScript / TypeScript runtime | Mob's host language is Elixir/Erlang/Gleam on BEAM; bridging JS would defeat the architecture |
| React reconciler | Mob has its own render tree; no React VDOM under it |
| CSS / Yoga flexbox engine | iOS uses SwiftUI layout; Android uses Compose layout; both are native flexbox-equivalents |
| `XMLHttpRequest` / `fetch` polyfill | Use Erlang/Elixir HTTP libraries directly (`:req`, `:finch`, `:gun`) |
| Babel / Metro / bundler | BEAM bytecode replaces JS bundling; `mix mob.push` ships `.beam` directly |

---

## How to use this matrix

- **Starting a new app**: scan the ❌ rows first to see what would need to be a plugin or worked around.
- **Reporting a gap**: if something here is wrong (mob has a capability I missed, or partial that's actually full), the doc is hand-maintained — please open a PR or flag it.
- **Filling a gap as a plugin**: see [MOB_PLUGINS.md](../MOB_PLUGINS.md) for the manifest spec. Most ❌ rows are plugin candidates (tier 1 or tier 2 depending on whether they ship UI).
- **Filling a gap in core**: when a capability is universal enough (every app needs it, both platforms support it cleanly) it's worth landing in core rather than as a plugin. The boundary is fuzzy; raising a discussion before doing the work is the right call.

This matrix isn't a roadmap commitment — it's a snapshot of reality.
Some ❌ rows may stay ❌ for a long time because no one's asked.
Others will land via community plugins. The intent is honest
disclosure, not a promise of feature parity with React Native.

---

## Related docs

- [`MOB_PLUGINS.md`](../MOB_PLUGINS.md) — plugin manifest spec for
  filling missing capabilities without merging into core
- [`RELEASE.md`](https://github.com/GenericJam/mob/blob/master/RELEASE.md) — release process if you're shipping a
  new capability that lands in core
- [`guides/styling.md`](styling.md) — visual styling for the
  components above (tokens, themes, dark mode)
- [`guides/support_matrix.md`](support_matrix.md) — minimum
  OS / ABI / SDK supported (a different "support matrix" —
  platform versions rather than capabilities)
