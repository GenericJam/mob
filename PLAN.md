# Mob — Build Plan

> A mobile framework for Elixir that runs the BEAM on-device.
> Last updated: 2026-04-15

---

## What's shipped

### Core framework
- ✅ `Mob.Socket`, `Mob.Screen`, `Mob.Component`, `Mob.Registry`, `Mob.Renderer`
- ✅ HelloScreen on Android emulator (Pixel 8) and real Moto phone (non-rooted)
- ✅ HelloScreen on iOS simulator (iPhone 17) via SwiftUI
- ✅ CounterScreen — tap → NIF → `enif_send` → `handle_event` → re-render (both platforms)
- ✅ Erlang distribution on Android (`Mob.Dist`, deferred 3s to avoid hwui mutex race)
- ✅ Erlang distribution on iOS (simulator shares Mac network stack, reads `MOB_DIST_PORT` env)
- ✅ Simultaneous Android + iOS connection — both nodes in one IEx cluster
- ✅ Battery benchmarking — Nerves tuning flags (`+sbwt none +S 1:1` etc.) adopted as production default in `mob_beam.c`
- ✅ `mob_nif:log/2` NIF + `Mob.AndroidLogger` OTP handler → Elixir Logger → mob_dev dashboard
- ✅ Navigation stack — `push_screen`, `pop_screen`, `pop_to_root`, `pop_to`, `reset_to` in `Mob.Socket`
- ✅ Animated transitions — `:push`, `:pop`, `:reset`, `:none` passed through renderer to NIF
- ✅ Back buttons on all demo screens; `handle_info` catch-all guards against FunctionClauseError crash (added to all 6 mob_demo screens)
- ✅ SELinux fix in deployer — `restorecon -RF` after `adb push` AND before `am start` in `restart_android` prevents MCS category mismatch on both initial deploy and APK reinstall
- ✅ `scroll` explicit wrapper — `axis: :vertical/:horizontal`, `show_indicator: false` (iOS); `HelloScreen`/`CounterScreen` wrap root column in scroll
- ✅ `Mob.Style` struct — `%Mob.Style{props: map}` wraps reusable prop maps; merged by renderer at serialisation time
- ✅ Style token system — atom tokens (`:primary`, `:xl`, `:gray_600`, etc.) resolved in `Mob.Renderer` before JSON serialisation; no runtime cost on the native side
- ✅ Platform blocks — `:ios` / `:android` nested prop keys resolved by renderer; wrong platform's block silently dropped
- ✅ Wave A components: `box` (ZStack), `divider`, `spacer` (fixed), `progress` (linear, determinate + indeterminate) — both platforms
- ✅ `ComponentsScreen` in mob_demo — exercises all Wave A components and style tokens
- ✅ Wave B components: `text_field` (keyboard types, focus/blur/submit events), `toggle`, `slider` — both platforms
- ✅ `InputScreen` in mob_demo — exercises text_field / toggle / slider with live event feedback
- ✅ `image` — `AsyncImage` (iOS built-in) + Coil (Android); `src`, `content_mode`, `width`, `height`, `corner_radius`, `placeholder_color` props
- ✅ `lazy_list` — `LazyVStack` (iOS) + `LazyColumn` (Android); `on_end_reached` event for infinite scroll
- ✅ `ListScreen` in mob_demo — 30 items initial, appends 20 on each end_reached

### Toolchain (all published on Hex)
- ✅ `mix mob.new APP_NAME` — generates full Android + iOS project from templates
- ✅ `mix mob.install` — first-run: downloads pre-built OTP, generates icons, writes mob.exs
- ✅ `mix mob.deploy [--native]` — compile + push BEAMs via adb/cp; `--native` also builds APK/app
- ✅ `mix mob.push` — compile + hot-push changed modules via Erlang dist (no restart)
- ✅ `mix mob.watch` — auto-push on file save via dist
- ✅ `mix mob.watch_stop` — stops a running mob.watch process
- ✅ `mix mob.connect` — tunnel + restart + wait for nodes + IEx
- ✅ `mix mob.battery_bench` — A/B test BEAM scheduler configs with mAh measurements
- ✅ `mix mob.icon` — regenerate icons (random robot or from source image)
- ✅ Pre-built OTP tarballs on GitHub (android + ios-sim), downloaded automatically

### mob_dev server (v0.2.2)
- ✅ Device discovery (adb + xcrun simctl), live device cards
- ✅ Per-device deploy buttons (Update / First Deploy)
- ✅ Live log streaming (logcat + iOS simulator log stream)
- ✅ Log filter (App / All / per-device) + free-text filter (comma-separated terms)
- ✅ Deploy output terminal inline per device card
- ✅ Elixir Logger → dashboard (mob_nif:log/2 pipeline)
- ✅ QR code in header — encodes LAN URL for opening dashboard on phone
- ✅ `mix mob.server` — starts server, binds to 0.0.0.0:4040, prints QR in terminal

---

## Deploy model (architectural decision 2026-04-14)

See `ARCHITECTURE.md` for the full write-up. Short version:

- **`mix mob.deploy --native`** — USB required. Full push: builds APK/IPA, installs via adb/xcrun, copies BEAMs.
- **`mix mob.deploy`** — USB optional. Fast push: compiles BEAMs, saves to mob_dev server, distributes to connected nodes via Erlang dist. Falls back to adb push if no dist connection.
- **`mix mob.push` / `mix mob.watch`** — dist only. Hot-loads changed modules in place, no restart.

USB is only required for first deploy. After that, Erlang distribution is the transport for all code updates across both Android and iOS.

---

## Next up

### 1. ~~Styling system — `Mob.Style`~~ ✅ Done

**Shipped (2026-04-15):**

- `%Mob.Style{props: map}` struct — thin wrapper so the future `~MOB` sigil can pattern-match on it; zero cost before serialisation
- Token resolution in `Mob.Renderer`: atom values for color props (`:primary`, `:gray_600`, etc.) resolve to ARGB integers; atom values for `:text_size` resolve to sp floats. Token tables are module attributes — compile-time constants
- Platform blocks — `:ios` / `:android` keys in props are resolved by renderer before serialisation; the other platform's block is dropped silently
- `%Mob.Style{}` under the `:style` prop key is merged into the node's own props; inline props override style values
- Demo screens converted to tokens; `ComponentsScreen` added

**Still to do (style-adjacent):**
- [ ] `~MOB` sigil: `style={...}` attribute support (Phase 2 — sigil upgrade)
- [ ] `depth/1`, `font_style/1` semantic abstractions — NIF changes needed on both platforms
- [ ] User-defined token extensions via `MyApp.Styles` + mob.exs config
- [ ] `font_weight`, `rounded`, `opacity`, `border` props on both platforms

---

### 2. ~~Event model extension — value-bearing events~~ ✅ Done

**Shipped (2026-04-15):**

- `{:change, tag, value}` — 3-tuple sent by NIFs for value-bearing inputs. Tap stays as `{:tap, tag}` (backward-compatible).
- Value types: binary string (text_field), boolean atom (toggle), float (slider)
- `on_change: {pid, tag}` prop registered via the existing tap handle registry; the C side determines whether to send `:tap` or `:change` based on which sender function is called
- Added to both platforms: `mob_send_change_str/bool/float` in Android `mob_nif.c`; static equivalents in iOS `mob_nif.m`
- Wave B components implemented: `text_field`, `toggle`, `slider` — both platforms
- `InputScreen` demo exercises all three with live state feedback

---

### 3. ~~Back button / hardware navigation~~ ✅ Done

**Shipped (2026-04-15):**

- Android `BackHandler` in `MainActivity` intercepts the system back gesture and calls `MobBridge.nativeHandleBack()` → `mob_handle_back()` C function
- iOS `UIScreenEdgePanGestureRecognizer` on `MobHostingController` (left edge) calls `mob_handle_back()` directly
- `mob_handle_back()` uses `enif_whereis_pid` to find `:mob_screen` and sends `{:mob, :back}` to the BEAM
- `Mob.Screen` intercepts `{:mob, :back}` before user's `handle_info` — automatic on all screens, no user code needed
- Nav stack non-empty → pops with `:pop` transition; stack empty → calls `exit_app/0` NIF
- `exit_app` on Android: `activity.moveTaskToBack(true)` (backgrounds, does not kill); on iOS: no-op (OS handles home gesture)
- `Mob.Screen` registers itself as `:mob_screen` on init (render mode only)

**Design decisions recorded:**
- "Home screen" = whatever is at the bottom of the stack after `reset_to`. No separate concept needed.
- After login, `reset_to(MainScreen)` zeroes the stack; back at root backgrounds the app.
- `moveTaskToBack` preferred over `finish()` — users achieve apps to persist in the switcher.
- Dynamic home screen (login vs main) is a `reset_to` convention, not a framework feature.

### 4. ~~Safe area insets~~ ✅ Done

**Shipped (2026-04-15):**

- `mob_nif:safe_area/0` → `{top, right, bottom, left}` floats (logical points / dp)
  - iOS: reads `UIWindow.safeAreaInsets` on the main thread via `dispatch_sync`
  - Android: reads `decorView.rootWindowInsets` via `CountDownLatch` in `MobBridge`
- `Mob.Screen.init` injects `assigns.safe_area = %{top: t, right: r, bottom: b, left: l}` before `mount/3` is called — always available, zero opt-in
- `MobRootView` uses `.ignoresSafeArea(.container, edges: [.bottom, .horizontal])` — top safe area respected automatically; bottom/sides fill edge-to-edge
- Framework does not insert any automatic padding — values are information only, developer decides what to do with them
- Documented in README under `## Display`

---

## Next up

### 5. ~~Per-edge padding~~ ✅ Done

**Shipped (2026-04-15):**
- `padding_top`, `padding_right`, `padding_bottom`, `padding_left` props on all layout nodes
- Any missing edge falls back to the uniform `padding` value; all absent → no padding
- iOS: `paddingEdgeInsets` computed property on `MobNode` returns `EdgeInsets`; all `.padding(node.padding)` calls in `MobRootView.swift` replaced with `.padding(node.paddingEdgeInsets)`
- Android: `nodeModifier` updated to detect edge props; uses `Modifier.padding(top=, end=, bottom=, start=)` when any edge is present, uniform `.padding()` otherwise
- Usage: `padding_top: trunc(assigns.safe_area.top) + 16, padding: 16` — top clears the status bar; sides and bottom get uniform 16dp padding

### 6. Typography

Text props that are missing on both platforms:

- `font: "Inter"` — custom font family by name; falls back to system font if not found
- `font_weight: :bold | :semibold | :medium | :regular | :light`
- `text_align: :left | :center | :right`
- `italic: true`
- `line_height` (multiplier, e.g. `1.4`)
- `letter_spacing` (sp/pt)

**Custom fonts:** bundled in the app as asset files (`.ttf` / `.otf`). Developer drops fonts into `priv/fonts/` in their Mix project; `mix mob.deploy --native` copies them into the right platform directories and patches `Info.plist` for iOS. iOS uses the PostScript name directly; Android requires lowercase+underscore filenames (`Inter-Regular.ttf` → `inter_regular`), so `Mob.Renderer` normalises the name before JSON serialisation.

Downloadable / web fonts (Google Fonts API etc.) are a nice-to-have for later — network-dependent and significantly more complex.

Token additions in `Mob.Renderer` for `font_weight`. NIF side: `font` / `text_weight` / `text_align` JSON fields → `UIFont(name:size:)` (iOS) / `FontFamily` + `FontWeight` (Android).

### 7. Tab bar / drawer navigation

Most real apps have a persistent tab bar (bottom nav) or a side drawer. Currently nav is a push/pop stack only.

**Tab bar:**
- Defined in `Mob.App.navigation/1` alongside the stack declaration (same place as today's `stack`)
- `tab_bar/1` macro takes a list of `{label, icon_atom, screen_module}` entries
- Active tab is part of `Mob.Screen` state; `Mob.Socket.switch_tab/2` sends to a sibling tab's screen
- Each tab has its own independent nav stack
- iOS: `UITabBarController` wrapper; Android: `NavigationBar` composable at the bottom

**Drawer:**
- `drawer/1` macro in `Mob.App.navigation/1`
- Opened by `Mob.Socket.open_drawer/1`, closed by `close_drawer/1`
- Rendered as a slide-in panel from the left; content is a regular screen tree

**Back-gesture interaction:** back gesture at stack root should go to previous tab if tabs are active, not background the app.

### 8. Nav animations — iOS

iOS `MobRootView` already has `navTransition/1` and `navAnimation/1` helpers and a `.transition()` modifier, but they're applied to the entire root view swap, not to individual screen transitions. The result is a whole-screen fade rather than a proper push slide.

**Goal:** Match Android's `AnimatedContent` behaviour — slide in from right (push), slide in from left (pop), fade (reset).

iOS approach: keep `MobRootView` as-is but switch `ZStack` + `.transition()` to `withAnimation` around the `currentRoot` state update, paired with `.transition(.asymmetric(...))` on `MobNodeView`. This is already scaffolded in the current code; needs the transition to be applied to the `MobNodeView` level rather than the `ZStack` level.

### 9. `mix mob.deploy` → dist
**Goal:** Align implementation with architecture decision.
Currently `mix mob.deploy` (non-native) uses `adb push` / `cp`. Change it to compile + push via Erlang dist when a node is reachable. Keep adb push as fallback for when dist isn't up.

### 10. `mix mob.watch` in mob_dev dashboard
**Goal:** "Push on save" toggle in the web UI — same logic as `mix mob.watch` but driven from the server.
- `MobDev.Server.WatchWorker` GenServer — wraps the watch loop
- Toggle switch in dashboard header starts/stops it
- Status indicator: last push time, module count, errors

### 11. `mix mob.routes` validation
**Goal:** Catch dead navigation references at compile/test time rather than at runtime.
- Walk all `push_screen`, `reset_to`, `pop_to` calls in the app
- Check each module atom against `Mob.Nav.Registry`
- Print a warning (or error with `--strict`) listing unregistered destinations
- Runs as part of `mix test` if `mix mob.routes` is in the test helpers

### 12. KitchenSink screen
All components exercised in one demo screen: `column`, `row`, `scroll`, `box`, `text`, `button`, `text_field`, `toggle`, `slider`, `divider`, `spacer`, `progress`, `image`, `lazy_list`.
Update after per-edge padding (item 5) and typography (item 6) land.

---

## List component overhaul

The current `lazy_list` requires the caller to `Enum.map` their data into pre-rendered node trees and pass them as children. The new `list` component gives Elixir developers something that behaves like a list out of the box, with full customisation available when needed.

### Component and event model

Every list lives inside a **wrapper component** — either one the developer explicitly defines, or an implicit one the framework creates automatically. List events surface at the wrapper boundary, never at the screen level unless the list is unwrapped.

**One list on a screen — list is its own implicit wrapper:**
```elixir
%{type: :list, props: %{id: :items, items: assigns.items, on_select: {self(), :items}}}

def handle_info({:select, :items, index}, socket), do: ...
def handle_info({:end_reached, :items}, socket), do: ...
def handle_info({:refresh, :items}, socket), do: ...
```

**Multiple lists — each wrapped in an explicit `Mob.Component`:**
```elixir
defmodule MyApp.RecentList do
  use Mob.Component

  def init(socket), do: Mob.Socket.assign(socket, :items, [])

  def render(assigns) do
    %{type: :list, props: %{id: :recent, items: assigns.items}}
  end

  # Events are contained here — never leak to the parent screen
  def handle_info({:select, :recent, index}, socket), do: ...
end
```

`Mob.Component` is the event isolation boundary. The developer never has to think about event routing leaking between lists as long as they follow the wrapper rule.

### Default data list

No boilerplate for the simple case. Default renderer shows each item as a text row:

```elixir
# Works immediately — renders each item as a plain text row
%{type: :list, props: %{id: :items, items: assigns.items}}
```

Default renderer logic: if item is a binary, render as text. If a map, look for `:label`, `:title`, or `:name` key, fall back to `inspect/1`.

### Custom renderer

Registered at mount time, referenced by the list by id:

```elixir
def mount(_params, _session, socket) do
  socket =
    socket
    |> Mob.Socket.assign(:items, [])
    |> Mob.List.put_renderer(socket, :items, &item_row/1)
  {:ok, socket}
end

defp item_row(item) do
  %{type: :row, props: %{padding: 12}, children: [
    %{type: :text, props: %{text: item.title}},
    %{type: :text, props: %{text: item.subtitle, text_color: :gray_500}}
  ]}
end
```

The renderer is a plain Elixir function stored in assigns. The BEAM calls it per item to produce children before handing off to the NIF — native-side virtualization still applies.

### Full props

```elixir
%{type: :list,
  props: %{
    id:              :my_list,
    items:           assigns.items,           # data, passed through renderer
    on_select:       {self(), :my_list},      # → {:select, :my_list, index}
    on_end_reached:  {self(), :my_list},      # → {:end_reached, :my_list}
    on_refresh:      {self(), :my_list},      # → {:refresh, :my_list}
    refreshing:      assigns.loading,         # shows pull-to-refresh spinner
    scroll_to:       assigns.scroll_index,    # jump to index (write-only)
  }}
```

Events arriving as `handle_info`:
- `{:select, id, index}` — row tapped; index is 0-based into `items`
- `{:end_reached, id}` — user scrolled near the bottom
- `{:refresh, id}` — pull-to-refresh gesture released
- `{:swipe, id, :left | :right, index}` — swipe action on a row (Phase 2)
- `{:scroll, id, %{index: n, offset: f}}` — scroll position (throttled, Phase 2)

### Swipe actions (Phase 2)

```elixir
%{type: :list_item,
  props: %{
    swipe_left:  [%{label: "Delete",  color: :red_600,  tag: :delete}],
    swipe_right: [%{label: "Archive", color: :blue_600, tag: :archive}],
  },
  children: [item_content_node]}
```

### Sections (Phase 2)

```elixir
%{type: :list, props: %{sticky_headers: true}, children: [
  %{type: :list_section, props: %{label: "Today"},     children: [...]},
  %{type: :list_section, props: %{label: "Yesterday"}, children: [...]},
]}
```

### Implementation notes

- `lazy_list` stays unchanged (backward compat). `list` is the new component.
- In `Mob.Renderer`, `type: :list` expands: items → children via renderer, then serialises as `lazy_list` to the NIF. No NIF changes needed for Phase 1.
- `on_select` implemented by wrapping each row in a tappable container in the renderer, with tag `{:list, id, :select, index}`. `Mob.Screen` intercepts `{:tap, {:list, id, :select, index}}` and re-dispatches as `{:select, id, index}`.
- `on_refresh` and `refreshing` require native changes (SwipeRefresh on Android, `.refreshable` on iOS) — Phase 2.
- iOS: `LazyVStack` for Phase 1; migrate to `List` view for swipe actions + sections in Phase 2.
- Android: `LazyColumn` for Phase 1; add `SwipeToDismiss` + `stickyHeader` in Phase 2.

---

## Device capabilities

Hardware APIs arrive as `handle_info` events, same as tap events. Permission requests are explicit — the developer calls `Mob.Permissions.request/2` and receives `{:permission, capability, :granted | :denied}` back.

### Permission model

```elixir
# Request a permission (shows OS dialog if not yet decided)
{:noreply, Mob.Permissions.request(socket, :camera)}

# Arrives as:
def handle_info({:permission, :camera, :granted}, socket), do: ...
def handle_info({:permission, :camera, :denied},  socket), do: ...
```

### Priority 1 — No permissions required

**Haptics**

Feedback for taps, errors, and successes. No permission needed.

```elixir
mob_nif:haptic(:light)    # light tap
mob_nif:haptic(:medium)   # medium tap
mob_nif:haptic(:heavy)    # heavy tap
mob_nif:haptic(:success)  # success pattern (iOS: UINotificationFeedbackGenerator)
mob_nif:haptic(:error)    # error pattern
mob_nif:haptic(:warning)  # warning pattern
```

Or from Elixir via a `Mob.Haptic` module that calls the NIF. Likely want a high-level `Mob.Socket.haptic/2` so screens can trigger haptics in `handle_info` without reaching for the NIF directly.

iOS: `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`
Android: `HapticFeedbackConstants` via `View.performHapticFeedback`

**Clipboard**

```elixir
# Write
Mob.Clipboard.put(socket, "some text")  # → {:clipboard, :ok}

# Read
Mob.Clipboard.get(socket)               # → {:clipboard, :ok, "some text"} | {:clipboard, :empty}
```

iOS: `UIPasteboard.general`
Android: `ClipboardManager`

**Share sheet**

Opens the OS share dialog with a piece of content. Fire-and-forget from the BEAM's perspective.

```elixir
Mob.Share.text(socket, "Check out Mob: https://...")
Mob.Share.file(socket, "/path/to/file.pdf", mime: "application/pdf")
```

iOS: `UIActivityViewController`
Android: `Intent.ACTION_SEND`

### Priority 2 — Runtime permissions required

**Biometric authentication**

```elixir
Mob.Biometric.authenticate(socket, reason: "Confirm payment")
# → {:biometric, :success} | {:biometric, :failure} | {:biometric, :not_available}
```

iOS: `LAContext.evaluatePolicy` (FaceID / TouchID — same call)
Android: `BiometricPrompt` (fingerprint / face / iris — same API)

**Location**

```elixir
# One-shot
Mob.Location.get_once(socket)
# → {:location, %{lat: 51.5, lon: -0.1, accuracy: 10.0, altitude: 20.0}}

# Continuous updates
Mob.Location.start(socket, accuracy: :high)
# → repeated {:location, %{...}} messages

Mob.Location.stop(socket)
```

iOS: `CLLocationManager`; `NSLocationWhenInUseUsageDescription` required in Info.plist
Android: `FusedLocationProviderClient`; `ACCESS_FINE_LOCATION` in manifest

Accuracy levels: `:high` (GPS, high battery), `:balanced`, `:low` (cell/wifi only)

**Camera**

```elixir
# Capture a photo — opens native camera UI, returns path to captured image
Mob.Camera.capture_photo(socket, quality: :high)
# → {:camera, :photo, %{path: "/tmp/mob_capture_xxx.jpg", width: 4032, height: 3024}}

# Capture video
Mob.Camera.capture_video(socket, max_duration: 60)
# → {:camera, :video, %{path: "/tmp/mob_capture_xxx.mp4", duration: 42.3}}

# Cancel arrives as:
# → {:camera, :cancelled}
```

iOS: `UIImagePickerController` (photo/video capture mode)
Android: `ActivityResultContracts.TakePicture` / `TakeVideo`

**Photo library picker**

```elixir
Mob.Photos.pick(socket, max: 3, types: [:image, :video])
# → {:photos, :picked, [%{path: ..., type: :image | :video, ...}]}
# → {:photos, :cancelled}
```

iOS: `PHPickerViewController` (no permission needed on iOS 14+)
Android: `ActivityResultContracts.PickMultipleVisualMedia`

**File picker**

```elixir
Mob.Files.pick(socket, types: ["application/pdf", "text/plain"])
# → {:files, :picked, [%{path: ..., name: ..., mime: ..., size: ...}]}
# → {:files, :cancelled}
```

iOS: `UIDocumentPickerViewController`
Android: `ActivityResultContracts.OpenMultipleDocuments`

### Priority 3 — Specialised

**Microphone / audio recording**

```elixir
Mob.Audio.start_recording(socket, format: :aac, quality: :medium)
# Recording in progress...
Mob.Audio.stop_recording(socket)
# → {:audio, :recorded, %{path: "/tmp/mob_audio_xxx.aac", duration: 12.4}}
```

**Accelerometer / gyroscope**

```elixir
Mob.Motion.start(socket, sensors: [:accelerometer, :gyro], interval_ms: 100)
# → repeated {:motion, %{accel: {x, y, z}, gyro: {x, y, z}, timestamp: ...}}
Mob.Motion.stop(socket)
```

iOS: `CMMotionManager`
Android: `SensorManager` with `TYPE_ACCELEROMETER` / `TYPE_GYROSCOPE`

**QR / barcode scanner**

```elixir
Mob.Scanner.scan(socket, formats: [:qr, :ean13, :code128])
# → {:scan, :result, %{type: :qr, value: "https://..."}}
# → {:scan, :cancelled}
```

iOS: `AVCaptureMetadataOutput` with `AVMetadataObjectTypeQRCode` etc
Android: `CameraX` + `BarcodeScanning` (ML Kit)

---

## Notifications

Two distinct mechanisms that share the same `handle_info` shape on the BEAM side.

### Local notifications

Scheduled by the app itself — no server, no internet. Useful for reminders, timers, recurring alerts.

```elixir
# Schedule a notification
Mob.Notify.schedule(socket,
  id:      "daily_reminder",
  title:   "Time to check in",
  body:    "Open the app to see today's updates",
  at:      ~U[2026-04-16 09:00:00Z],   # or delay_seconds: 3600
  data:    %{screen: "reminders"}
)
# → {:notify, :scheduled, "daily_reminder"}

# Cancel a pending notification
Mob.Notify.cancel(socket, "daily_reminder")

# Arriving while the app is in the foreground:
def handle_info({:notification, %{id: id, data: data, source: :local}}, socket), do: ...
```

iOS: `UNUserNotificationCenter`
Android: `NotificationManager` + `AlarmManager` for scheduling

### Push notifications (mob_push)

Server-originated. Requires FCM (Android) and APNs (iOS) registration.

```elixir
# In your App start/0, request permission and subscribe to push
Mob.Notify.register_push(socket)
# → {:push_token, platform, token_string}  — send this to your server

# Arriving while app is in foreground:
def handle_info({:notification, %{title: t, body: b, data: d, source: :push}}, socket), do: ...
```

Background delivery (app not running) is handled by the OS — tapping the notification launches the app and passes `data` into `mount/3` params.

**`mob_push` package** (separate Hex package, not part of core `mob`):
- Elixir server library: `MobPush.send(token, platform, %{title: ..., body: ..., data: ...})`
- Wraps FCM HTTP v1 API (Android) and APNs HTTP/2 (iOS)
- Token storage + fanout not included — bring your own persistence

### Notification permission

Both local and push require `POST_NOTIFICATIONS` (Android 13+) / `UNAuthorizationOptions` (iOS). Same `Mob.Permissions` model:

```elixir
Mob.Permissions.request(socket, :notifications)
# → {:permission, :notifications, :granted | :denied}
```

---

## Phase 2

### `~MOB` sigil upgrade
Upgrade from single-element to full nested tree. Heredoc form becomes the primary way to write screens:

```elixir
def render(assigns) do
  ~MOB"""
  <Column style={@screen_bg}>
    <Text style={@heading} text="Title" />
    <Text p={4} color={:gray_900} text={assigns.greeting} />
    <Button style={@btn_primary} text="Go" on_tap={{self(), :go}} />
  </Column>
  """
end
```

Single-element form stays valid for inline use. Both compile to the same node map tree.

### Generators (Igniter)
`mix mob.gen.screen`, `mix mob.gen.component`, `mix mob.gen.release` — using Igniter for idiomatic AST-aware code generation. Same infrastructure as `mix phx.gen.live`. AI agents use generators as the blessed path rather than writing from scratch.

### Physical iOS device
Needs `iproxy` (from libimobiledevice) for USB dist port tunneling:
- `iproxy 9101 9101` forwards Mac port 9101 → device port 9101 over USB
- `mob_beam.m` already reads `MOB_DIST_PORT` from env; no BEAM changes needed
- `mix mob.connect` needs to detect a plugged-in iOS device and start iproxy
- App must be signed with a development provisioning profile (free Apple account works for testing)
- `--disable-jit` flag required in BEAM args (iOS enforces W^X; JIT is blocked on device, not simulator)
- `mob_new` template needs an Xcode project or build script that accepts a signing identity

### Offline / local storage
SQLite via NIF. `Mob.Repo` with Elixir schema + migrations on app start. WAL mode default.
- Wraps `esqlite` or custom NIF (bundled SQLite `.c` file, statically linked)
- `Mob.Repo.query/2`, `Mob.Repo.transaction/2`
- Migration files in `priv/migrations/` — run on every app start, idempotent

### App Store / Play Store build pipeline
`mix mob.release --platform android|ios` — Gradle/Xcode build, signing, `.aab` / `.ipa` output. Fastlane for upload.

### User-defined style tokens
`MyApp.Styles` module + `mob.exs` config key. Developer defines their own color palette, type scale, spacing scale as token maps. `Mob.Renderer` merges app tokens on top of the default set at compile time.

---

## Component vocabulary

Both platforms use the same column/row layout model (Compose `Column`/`Row`, SwiftUI `VStack`/`HStack`) — the same mental model as Tailwind's flexbox. No "table" component; both platforms abandoned that in favour of styled list cells.

| Mob tag | Compose | SwiftUI | Status |
|---|---|---|---|
| `column` | `Column` | `VStack` | ✅ done |
| `row` | `Row` | `HStack` | ✅ done |
| `box` | `Box` | `ZStack` | ✅ done |
| `scroll` | `ScrollView` + `Column` | `ScrollView` | ✅ done |
| `text` | `Text` | `Text` | ✅ done |
| `button` | `Button` | `Button` | ✅ done |
| `divider` | `HorizontalDivider` | `Divider` | ✅ done |
| `spacer` | `Spacer` (fixed size) | `Spacer` | ✅ done |
| `progress` | `LinearProgressIndicator` | `ProgressView` | ✅ done |
| `text_field` | `TextField` | `TextField` | ✅ done |
| `toggle` | `Switch` | `Toggle` | ✅ done |
| `slider` | `Slider` | `Slider` | ✅ done |
| `image` | `AsyncImage` (Coil) | `AsyncImage` | ✅ done |
| `lazy_list` | `LazyColumn` | `LazyVStack` | ✅ done |
| `list` | `LazyColumn` + swipe/sections | `List` | ⬜ planned |
| `list_section` | `stickyHeader` | `Section` | ⬜ planned |

**Spacer note:** fixed-size spacers are implemented (`size` prop in dp). Fill-available-space (flex) spacers require threading `ColumnScope`/`RowScope` context through `RenderNode` — Phase 2.

---

## Key technical constraints

1. **`enif_get_long` for color params** — ARGB 0xFFFFFFFF overflows `enif_get_int`. Always use `enif_get_long`.
2. **Cache JNI class refs in `JNI_OnLoad`** — `FindClass` fails on non-main threads. `mob_ui_cache_class(env)` caches all refs upfront.
3. **CountDownLatch needs try/finally** — if the Runnable throws, latch never fires → deadlock.
4. **`enif_keep_resource` for tap listeners** — Java holds raw ptr; GC must not free the resource.
5. **Android dist deferred 3s** — starting distribution at BEAM launch races with hwui thread pool → SIGABRT. `Mob.Dist.ensure_started/1` defers `Node.start/2` by 3 seconds.
6. **ERTS helpers as `.so` files in jniLibs** — SELinux blocks `execve` from `app_data_file`; packaging as `lib*.so` gets `apk_data_file` label which allows exec.
7. **`+C` flags invalid in `erl_start` argv** — when calling `erl_start` directly (bypassing `erlexec`), all emulator flags use `-` prefix. `+C multi_time_warp` → `-C multi_time_warp`. OTP 28+ default is already `multi_time_warp`, safe to omit.
8. **iOS OTP path** — `mob_beam.m` reads from `/tmp/otp-ios-sim`; deployer prefers that path when it exists. Cache dir (`~/.mob/cache/otp-ios-sim-XXXX/`) is fallback only.
9. **`--disable-jit` for real iOS devices** — iOS enforces W^X; JIT writes+executes memory which is blocked. Simulator builds can keep JIT. Android unaffected.
10. **Android BEAM stderr → `/dev/null`** — silent `exit(1)` from ERTS arg parse errors is the symptom. Check flags carefully; use logcat wrapper to surface boot errors.

---

## Hex packages

- `mob` v0.2.0 — github.com/genericjam/mob, MIT
- `mob_dev` v0.2.2 — github.com/genericjam/mob_dev, MIT
- `mob_new` v0.1.6 — archive, `mix archive.install hex mob_new`
