# Mob — Build Plan

> A mobile framework for Elixir that runs the BEAM on-device.
> Last updated: 2026-04-16

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
- ✅ `mob_nif:log/2` NIF + `Mob.NativeLogger` OTP handler → Elixir Logger → platform system log (logcat / NSLog) on both Android and iOS
- ✅ Navigation stack — `push_screen`, `pop_screen`, `pop_to_root`, `pop_to`, `reset_to` in `Mob.Socket`
- ✅ Animated transitions — `:push`, `:pop`, `:reset`, `:none` passed through renderer to NIF
- ✅ Back buttons on all demo screens; `handle_info` catch-all guards against FunctionClauseError crash (added to all 6 mob_demo screens)
- ✅ SELinux fix in deployer — `chcon -hR` (not `-R`) copies MCS category from app's own `files/` dir after push AND before restart, preventing category mismatch. `-h` flag prevents symlink dereferencing — critical because `mob_beam.c` symlinks `BINDIR/erl_child_setup → nativeLibDir/liberl_child_setup.so`, and `-R` would follow those symlinks and corrupt the native lib labels
- ✅ Android 15 `apk_data_file` fix — streaming `adb install` on Android 15 labels ERTS helper `.so` files (`liberl_child_setup.so` etc.) as `app_data_file` (blocks `execute_no_trans`). `mix mob.deploy --native` now runs `fix_erts_helper_labels/2` after each APK install: uses `pm dump` to find native lib dir, then `chcon u:object_r:apk_data_file:s0` on the 3 helpers (rooted/emulator only — silently skipped on production builds)
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
- ✅ `Mob.List` — high-level list component wrapping `lazy_list`; `on_select`, `on_end_reached` events; default and custom renderers; event routing via `{:list, id, :select, index}` tuples intercepted in `Mob.Screen` and re-dispatched as `{:select, id, index}`
- ✅ `ListScreen` in mob_demo — 30 items initial, appends 20 on each end_reached; both default and custom renderers exercised
- ✅ `Mob.Test` — RPC-based app automation for programmatic testing: `screen/1`, `assigns/1`, `tap/2`, `find/2`, `inspect/1`; drives running apps without touching native UI; used for QA tour and regression testing

### QA fixes (2026-04-16)
- ✅ `renderer.ex` — `on_tap` with tuple tag (e.g. `{:list, id, :select, index}`) no longer crashes `Atom.to_string/1`; split into two clauses: atom tag includes `accessibility_id`, non-atom tag omits it
- ✅ `tab_screen.ex` (mob_demo) — `text_size: "2xl"` (string) changed to `text_size: :"2xl"` (atom); renderer's token resolution requires atoms
- ✅ `MobRootView.swift` — Tab content frame fixed: added `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` to `MobNodeView` in `MobTabView` so content is top-aligned, not bottom-aligned
- ✅ `MobRootView.swift` — Tab background fill fixed: `MobTabView` applies `child.backgroundColor` to the outer frame wrapper so the tab area background fills to the bottom, not just behind content
- ✅ `device_screen.ex` (mob_demo) — Motion throttle fixed: `rem(data.timestamp, 5) == 0` is always true for 100ms-interval timestamps (all divisible by 5); corrected to `rem(div(data.timestamp, 100), 5) == 0`

### Toolchain (all published on Hex)
- ✅ `mix mob.new APP_NAME` — generates full Android + iOS project from templates
- ✅ `mix mob.install` — first-run: downloads pre-built OTP, generates icons, writes mob.exs
- ✅ `mix mob.deploy [--native]` — compile + push BEAMs via Erlang dist (no restart) when nodes are connected; falls back to adb/cp + restart when not; `--native` also builds APK/app bundle
- ✅ `mix mob.push` — compile + hot-push changed modules via Erlang dist (no restart)
- ✅ `mix mob.watch` — auto-push on file save via dist
- ✅ `mix mob.watch_stop` — stops a running mob.watch process
- ✅ `mix mob.routes` — validates all `push_screen`/`reset_to`/`pop_to` call targets against `Mob.Nav.Registry`; warns on unregistered destinations
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
- ✅ "Push on save" toggle in dashboard — `MobDev.Server.WatchWorker` GenServer; toggle in UI starts/stops file watching + dist push; shows last push time and module count
- ✅ `HotPush` NIF tolerance — `on_load_failure` from `:code.load_binary` is silently ignored for NIF modules (`:mob_nif`, `Vix.Nif` etc.) that are already loaded and can't be re-initialized; prevents false deploy failures

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

### 6. ~~Typography~~ ✅ Done

**Shipped (2026-04-15):**
- `font_weight: :bold | :semibold | :medium | :regular | :light | :thin`
- `text_align: :left | :center | :right`
- `italic: true`
- `line_height` multiplier (e.g. `1.4`) — converted to inter-line spacing on both platforms
- `letter_spacing` in sp/pt
- `font: "FontName"` — custom family; falls back to system font if not installed
- No renderer changes needed — OTP's `:json.encode` serialises atom values as strings
- iOS: `resolvedFont` + `textAlignEnum` + `computedLineSpacing` computed properties on MobNode Swift extension; applied to label case in `MobRootView`
- Android: `fontWeightProp`, `textAlignProp`, `fontFamilyProp` helpers in `MobBridge.kt`; applied to `MobText` composable
- Font bundling (`priv/fonts/` + `mix mob.deploy --native`) is a separate step

### 7. ~~Tab bar / drawer navigation~~ ✅ Done (tab bar; drawer Phase 2)

**Shipped (2026-04-15):**
- `type: :tab_bar` node with `tabs: [%{id:, label:, icon:}]`, `active:`, `on_tab_select:`
- Tab selection sends `{:change, tag, tab_id_string}` to screen's `handle_info` (reuses existing change mechanism)
- `on_tab_select: {self(), tag}` registered in `Mob.Renderer.prepare_props/3`
- iOS: `MobTabView` SwiftUI struct using `TabView` with SF Symbol icons; `MobNodeTypeTabBar` added to enum
- Android: `MobTabBar` composable using `Scaffold` + `NavigationBar`; `tabDefsProp` parses `JSONArray` from props
- `MobDemo.TabScreen` demo with 3 tabs, also exercises typography props

### 8. ~~Nav animations — iOS~~ ✅ Done

**Shipped (2026-04-15):**
- Added `@State private var currentTransition: String = "none"` to `MobRootView`
- Set `currentTransition = t` BEFORE the `withAnimation` block so the modifier sees the right value when the new view is inserted
- Added `.id(model.rootVersion)` to `MobNodeView` — forces SwiftUI to treat each root update as a distinct view insertion/removal, enabling asymmetric push/pop slide transitions rather than a whole-screen fade

### ~~(9, 10, 11 assigned elsewhere)~~

### 12. (KitchenSink — deferred to later)

---

## Device capabilities — shipped

### Haptics ✅ Done (2026-04-15)

No permission required.

```elixir
Mob.Haptic.trigger(socket, :light)    # brief tap
Mob.Haptic.trigger(socket, :medium)   # standard tap
Mob.Haptic.trigger(socket, :heavy)    # strong tap
Mob.Haptic.trigger(socket, :success)  # success pattern
Mob.Haptic.trigger(socket, :error)    # error pattern
Mob.Haptic.trigger(socket, :warning)  # warning pattern
```

Returns socket unchanged so it can be used inline. Fire-and-forget (dispatch_async / runOnUiThread).
- iOS: `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`
- Android: `View.performHapticFeedback` with `HapticFeedbackConstants`
- NIF: `mob_nif:haptic/1` on both platforms

### Clipboard ✅ Done (2026-04-15)

No permission required.

```elixir
Mob.Clipboard.put(socket, "some text")
case Mob.Clipboard.get(socket) do
  {:clipboard, :ok, text} -> ...
  {:clipboard, :empty}    -> ...
end
```

`get/1` is synchronous (dispatch_sync / CountDownLatch), same pattern as `safe_area/0`.
- iOS: `UIPasteboard.generalPasteboard`
- Android: `ClipboardManager` / `ClipData`
- NIFs: `mob_nif:clipboard_put/1`, `mob_nif:clipboard_get/0`

### Share sheet ✅ Done (2026-04-15)

No permission required. Fire-and-forget.

```elixir
Mob.Share.text(socket, "Check out Mob!")
```

- iOS: `UIActivityViewController` with popover support for iPad
- Android: `Intent.ACTION_SEND` via `Intent.createChooser`
- NIF: `mob_nif:share_text/1`

---

### Typography (original item 6)

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

### ~~9. `mix mob.deploy` → dist~~ ✅ Done

**Shipped (2026-04-16):**
`mix mob.deploy` now tries Erlang dist first (hot-loads with no restart); falls back to adb push + restart when no dist connection. NIF modules that fail hot-reload (`on_load_failure`) are silently tolerated.

### ~~10. `mix mob.watch` in mob_dev dashboard~~ ✅ Done

**Shipped (2026-04-16):**
`MobDev.Server.WatchWorker` GenServer wraps the watch loop. Toggle in dashboard UI starts/stops it with last-push-time and module-count status.

### ~~11. `mix mob.routes` validation~~ ✅ Done

**Shipped (2026-04-16):**
`mix mob.routes` walks all `push_screen`/`reset_to`/`pop_to` call sites, checks targets against `Mob.Nav.Registry`, and warns on unregistered destinations.

### 12. KitchenSink screen
All components exercised in one demo screen: `column`, `row`, `scroll`, `box`, `text`, `button`, `text_field`, `toggle`, `slider`, `divider`, `spacer`, `progress`, `image`, `lazy_list`.
Update after per-edge padding (item 5) and typography (item 6) land.

### 13. Permission / capability build wizard (mob_dev dashboard)

**Problem:** Native permission declarations must be in place at build time — `AndroidManifest.xml` for Android, `Info.plist` for iOS — but today developers have to edit those files by hand. This is one of the most friction-heavy parts of the first-deploy flow, especially for less experienced mobile developers.

**Goal:** A wizard in the mob_dev dashboard that lets developers declare which device capabilities their app uses. The wizard writes the correct platform manifest entries and regenerates files before the next `mix mob.deploy --native`.

**UX sketch:**

The wizard lives in the mob_dev dashboard under a "Build Config" or "Capabilities" tab. It shows a checklist of capabilities:

| Capability | Description | Android permission | iOS key |
|---|---|---|---|
| Camera | Capture photo / video | `CAMERA` | `NSCameraUsageDescription` |
| Microphone | Audio recording | `RECORD_AUDIO` | `NSMicrophoneUsageDescription` |
| Location (coarse) | Cell/wifi position | `ACCESS_COARSE_LOCATION` | `NSLocationWhenInUseUsageDescription` |
| Location (fine) | GPS | `ACCESS_FINE_LOCATION` | (same key, finer entitlement) |
| Photo library read | Pick photos | `READ_MEDIA_IMAGES` (API 33+) / `READ_EXTERNAL_STORAGE` | `NSPhotoLibraryUsageDescription` |
| Photo library write | Save photos | `WRITE_EXTERNAL_STORAGE` (API < 29) | `NSPhotoLibraryAddUsageDescription` |
| Notifications (local) | Schedule local alerts | `POST_NOTIFICATIONS` (API 33+) | (permission requested at runtime) |
| Biometric | FaceID / fingerprint | `USE_BIOMETRIC` | `NSFaceIDUsageDescription` |
| Bluetooth | BLE scan/connect | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | `NSBluetoothAlwaysUsageDescription` |
| NFC | Tag read/write | `NFC` | `NFCReaderUsageDescription` |

Each capability has an optional **usage description** field (iOS requires a human-readable string explaining why the app needs it; Android 13+ notifications also require one).

**Implementation:**

- Capability selections + usage strings stored in `mob.exs` under a `:capabilities` key
- `mix mob.deploy --native` reads `mob.exs[:capabilities]` and patches:
  - `android/app/src/main/AndroidManifest.xml` — adds `<uses-permission>` entries
  - `ios/Info.plist` — adds `NS*UsageDescription` keys
- `mix mob.new` generates starter manifests with a comment block where Mob will inject permissions; this makes the files safe to patch idempotently
- Dashboard wizard writes to `mob.exs` in the project root via a LiveView form; changes take effect on next `--native` build
- Validation: warn if a `Mob.*` API is called in the BEAM code but the corresponding capability is not declared (cross-reference `Mob.Camera`, `Mob.Location` etc. call sites vs declared capabilities)

**mob.exs format:**

```elixir
import Config

config :mob_dev,
  bundle_id: "com.example.myapp",
  capabilities: [
    camera:       [usage: "Take profile photos"],
    microphone:   [usage: "Record voice memos"],
    location:     [accuracy: :coarse, usage: "Show nearby places"],
    photo_library:[access: :read, usage: "Choose a profile picture"],
    notifications:[],
    biometric:    [usage: "Confirm payments with Face ID"],
  ]
```

**Scope note:** The wizard UI and `mob.exs` schema live in `mob_dev`. The manifest patching logic (`patch_android_manifest/1`, `patch_ios_plist/1`) lives in `mob_dev` alongside `NativeBuild`. The capability→permission mapping table is a compile-time constant in `mob_dev`.

---

## List component overhaul ✅ Phase 1 shipped (2026-04-15)

`Mob.List` Phase 1 is live. `lazy_list` stays for backward compat; `list` is the new component. Phase 2 items (swipe actions, sections, pull-to-refresh) are still pending.

The current `lazy_list` requires the caller to `Enum.map` their data into pre-rendered node trees and pass them as children. The `list` component gives Elixir developers something that behaves like a list out of the box, with full customisation available when needed.

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

## `Mob.Intent` — Android inter-app communication (planned)

Expose Android intents to Elixir so apps can reach out to other apps on the device (WhatsApp, email, browser, dialer, etc.).

### Elixir API

```elixir
# Send a message to a specific app (e.g. WhatsApp)
Mob.Intent.send(socket, package: "com.whatsapp", text: "Hello from the agent")

# Share sheet (existing Mob.Share) — chooser, no target package
Mob.Intent.send(socket, text: "Hello")

# Compose email
Mob.Intent.email(socket, to: "foo@example.com", subject: "Hi", body: "...")

# Open URL in browser
Mob.Intent.open_url(socket, "https://example.com")

# Open dialer (does not auto-dial)
Mob.Intent.dial(socket, "+1-555-1234")

# SMS
Mob.Intent.sms(socket, to: "+1-555-1234", body: "Hello")

# List installed apps the device can handle (subject to Android 11+ query restrictions)
Mob.Intent.installed_apps(socket)
# → arrives as {:intent_result, :installed_apps, [{package, label}, ...]}
```

All calls are fire-and-forget except `installed_apps` which delivers a result via `handle_info`.

### Android implementation

- `mob_intent_send/1`, `mob_intent_email/1`, `mob_intent_open_url/1`, `mob_intent_dial/1`, `mob_intent_sms/1`, `mob_intent_installed_apps/0` NIFs in `mob_nif.c` / `MobBridge.kt`
- `ACTION_SEND` with `setPackage(package)` for targeted sends; `createChooser` when no package specified
- `ACTION_SENDTO` with `mailto:` / `smsto:` URIs for email and SMS
- `ACTION_VIEW` for URLs and dialer
- `PackageManager.queryIntentActivities` for installed apps (requires `<queries>` entries in `AndroidManifest.xml`)
- All UI operations dispatch to main thread via `activity.runOnUiThread`

### iOS

Most of these map to `UIApplication.shared.open(url:)` with URL schemes:
- `whatsapp://send?text=...` — WhatsApp deep link
- `mailto:?to=...&subject=...&body=...`
- `http://` / `https://` — opens Safari
- `tel:` — opens Phone app
- `sms:?body=...`

iOS requires declaring URL schemes in `Info.plist` under `LSApplicationQueriesSchemes` to call `canOpenURL`. The capability build wizard (item 13) should handle this.

### Notes

- Android 11+ restricts `PackageManager.getInstalledApplications` — Play Store apps must declare specific `<queries>` or request `QUERY_ALL_PACKAGES` (restricted permission). `installed_apps` will only return apps the manifest declares queries for.
- Targeted sends (`package:`) silently fall back to the chooser if the target app is not installed.
- iOS does not have a general intent system; `Mob.Intent` on iOS is a URL scheme bridge.

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

---

## Device capabilities — shipped (continued)

### Permissions ✅ Done (2026-04-15)

```elixir
Mob.Permissions.request(socket, :camera)
def handle_info({:permission, :camera, :granted | :denied}, socket), do: ...
```

Capabilities: `:camera`, `:microphone`, `:photo_library`, `:location`, `:notifications`

### Biometric authentication ✅ Done (2026-04-15)

```elixir
Mob.Biometric.authenticate(socket, reason: "Confirm payment")
def handle_info({:biometric, :success | :failure | :not_available}, socket), do: ...
```

iOS: `LAContext.evaluatePolicy`. Android: `BiometricPrompt` (requires `androidx.biometric:biometric:1.1.0`).

### Location ✅ Done (2026-04-15)

```elixir
Mob.Location.get_once(socket)
Mob.Location.start(socket, accuracy: :high)
Mob.Location.stop(socket)
def handle_info({:location, %{lat: lat, lon: lon, accuracy: acc, altitude: alt}}, socket), do: ...
```

iOS: `CLLocationManager`. Android: `FusedLocationProviderClient` (requires `com.google.android.gms:play-services-location:21.0.1`).

### Camera capture ✅ Done (2026-04-15)

```elixir
Mob.Camera.capture_photo(socket)           # → {:camera, :photo, %{path:, width:, height:}}
Mob.Camera.capture_video(socket)           # → {:camera, :video, %{path:, duration:}}
                                           # or {:camera, :cancelled}
```

iOS: `UIImagePickerController`. Android: `TakePicture`/`CaptureVideo` activity contracts.

### Photo library picker ✅ Done (2026-04-15)

```elixir
Mob.Photos.pick(socket, max: 3, types: [:image, :video])
def handle_info({:photos, :picked, items}, socket), do: ...   # items: [%{path:, type:, ...}]
def handle_info({:photos, :cancelled},     socket), do: ...
```

iOS: `PHPickerViewController`. Android: `PickMultipleVisualMedia`.

### File picker ✅ Done (2026-04-15)

```elixir
Mob.Files.pick(socket, types: ["application/pdf"])
def handle_info({:files, :picked, items}, socket), do: ...   # items: [%{path:, name:, mime:, size:}]
def handle_info({:files, :cancelled},     socket), do: ...
```

iOS: `UIDocumentPickerViewController`. Android: `OpenMultipleDocuments`.

### Video playback ✅ Done (2026-04-15)

```elixir
%{type: :video, props: %{src: "/path/to/file.mp4", autoplay: true, loop: false, controls: true}, children: []}
```

iOS: `AVPlayerViewController` wrapped in `UIViewControllerRepresentable`. Android: Stub — full implementation requires `androidx.media3:media3-exoplayer:1.3.0` (see component docs).

### Microphone / audio recording ✅ Done (2026-04-15)

```elixir
Mob.Audio.start_recording(socket, format: :aac, quality: :medium)
Mob.Audio.stop_recording(socket)
def handle_info({:audio, :recorded, %{path: path, duration: secs}}, socket), do: ...
```

iOS: `AVAudioRecorder`. Android: `MediaRecorder`.

### Motion sensors ✅ Done (2026-04-15)

```elixir
Mob.Motion.start(socket, sensors: [:accelerometer, :gyro], interval_ms: 100)
Mob.Motion.stop(socket)
def handle_info({:motion, %{accel: {ax,ay,az}, gyro: {gx,gy,gz}, timestamp: ms}}, socket), do: ...
```

iOS: `CMMotionManager`. Android: `SensorManager`.

### QR / barcode scanner ✅ Done (2026-04-15)

```elixir
Mob.Scanner.scan(socket, formats: [:qr])
def handle_info({:scan, :result,    %{type: :qr, value: "..."}}, socket), do: ...
def handle_info({:scan, :cancelled},                               socket), do: ...
```

iOS: `AVCaptureMetadataOutput` + `MobScannerViewController`. Android: `MobScannerActivity` with CameraX + ML Kit (requires `com.google.mlkit:barcode-scanning:17.2.0` + CameraX deps).

### Notifications (local + push) ✅ Done (2026-04-15)

All notifications arrive via `handle_info` regardless of app state. When the app is killed and relaunched via a notification tap, the payload is stored at launch time and delivered after the root screen's `mount/3` completes.

**iOS setup:** In your `AppDelegate`/scene delegate, call `mob_set_launch_notification_json(json)` for remote-notification launches, and `mob_send_push_token(hexToken)` from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.

**Android setup:** `NotificationReceiver` BroadcastReceiver handles scheduled local notifications. Push requires adding `com.google.firebase:firebase-messaging` to build.gradle and uncommenting the FCM token retrieval in `MobBridge.notify_register_push`.

### 12. KitchenSink screen — moved to Phase 2 backlog

---

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

### Mob.Cluster

Connect Mob apps to each other — or to any Elixir/OTP node — at runtime without a server in the middle.

Two phones that share a cookie become a cluster. Every OTP primitive works across the connection: `:rpc.call`, `send` to a remote pid, distributed GenServer, global process registry. This is not a messaging protocol built on WebSockets — it is Erlang distribution, which has been doing this since 1986.

**Rendezvous options:**
- Server-mediated: both apps fetch a session cookie from your backend, call `Node.set_cookie/2` + `Node.connect/1`
- QR code: one app displays a QR containing its node name + cookie; the other scans and connects
- mDNS / local broadcast: apps discover each other on the same network without any server

**Cookie rotation:** `Node.set_cookie/2` works at runtime with no restart, so session cookies can be rotated between cluster sessions without stopping the BEAM.

**Scope:** `Mob.Cluster` is a thin API over `Node.set_cookie/2`, `Node.connect/1`, `Node.disconnect/1`, and `Mob.Dist.stop/0`. The heavy lifting is already in OTP.

```elixir
# Two phones, one line each:
Mob.Cluster.join(:"other_app@192.168.1.42", cookie: :session_abc)

# Then standard OTP across devices:
:rpc.call(:"other_app@192.168.1.42", MyApp.GameServer, :move, [:left])
```

### OTA BEAM updates (on-demand distribution)

Push new `.beam` files to installed production apps without an App Store release.

**Mechanism:** app polls an HTTP endpoint for an update manifest. When an update is available, it starts EPMD + Erlang distribution on-demand, connects outbound to the update server's BEAM node, receives new BEAMs via `:code.load_binary`, then shuts distribution back down. Distribution is never persistently open — it lives only for the duration of the update session.

```
App (on device)                     Update server (Elixir)
    │
    ├── GET /updates/check           ← signed manifest or 304
    │       {version, cookie, modules: [...]}
    │
    ├── Mob.Dist.ensure_started/1    ← start EPMD + dist on-demand
    │       (epmd_port: from manifest)
    │
    ├── Node.connect(server_node)    ← outbound connection; no open inbound port
    │
    ├── :rpc.call → :code.load_binary for each module
    │
    └── Mob.Dist.stop/0              ← shut down EPMD + dist when done
```

**Properties:**
- Phone initiates — no inbound ports need to be open on the device
- Cookie can be session-scoped (rotated per manifest) rather than static
- EPMD port configurable via manifest to avoid the 4369/adb conflict on dev machines
- Graceful fallback: if distribution fails, App Store update is still the backstop
- No App Store review for Elixir/BEAM changes (binary compatibility permitting)

**Scope:** requires `Mob.Dist.stop/0` (not yet implemented), manifest signing, and a server-side update distribution service. `mix mob.release` should produce a manifest alongside the build artifacts.

### User-defined style tokens
`MyApp.Styles` module + `mob.exs` config key. Developer defines their own color palette, type scale, spacing scale as token maps. `Mob.Renderer` merges app tokens on top of the default set at compile time.

---

## Nice to have

### Mob.Bluetooth + Mob.NFC

Device APIs following the same async `handle_info` pattern as `Mob.Camera` and
`Mob.Location`. NIF implementation only — no special BEAM changes required.

**`Mob.Bluetooth`** — BLE peripheral interaction (heart rate monitors, IoT
sensors, custom peripherals). iOS CoreBluetooth / Android BluetoothLE.

```elixir
Mob.Bluetooth.scan(socket)
# → {:bluetooth, :discovered, %{id: "AA:BB:...", name: "My Sensor", rssi: -62}}

Mob.Bluetooth.connect(socket, "AA:BB:...")
Mob.Bluetooth.read(socket, service_uuid, characteristic_uuid)
# → {:bluetooth, :read, %{uuid: "...", value: <<0x42>>}}
```

BLE peripheral mode (phone advertises itself) is also worth supporting — it is
a natural `Mob.Cluster` rendezvous mechanism: two phones exchange node name +
session cookie over BLE, then form an Erlang distribution cluster over TCP
without needing a server or shared WiFi network.

**`Mob.NFC`** — read/write NFC tags, peer-to-peer exchange. iOS requires a
background NFC entitlement for unsolicited reads; tag writing is more open.

```elixir
Mob.NFC.read(socket)
# → {:nfc, :tag, %{type: :ndef, records: [%{type: "text/plain", data: "hello"}]}}

Mob.NFC.write(socket, records)
# → {:nfc, :written}
```

NFC tap-to-connect is the most ergonomic `Mob.Cluster` bootstrap: tap two
phones together to exchange credentials, cluster forms automatically. Worth
implementing `Mob.Cluster` first so the NFC and BLE rendezvous flows have
something to connect to.

### Auth (`mix mob.gen.auth`)

Inspired by `mix phx.gen.auth` — a generator that scaffolds a complete auth layer for the app based on what the developer wants. Uses Igniter for AST-aware code generation so it integrates cleanly with the existing project rather than overwriting files.

**Generator interaction:**

```
$ mix mob.gen.auth

Which auth strategies do you want? (select all that apply)
  [x] Email + password
  [x] Sign in with Apple
  [x] Google Sign-In
  [ ] Phone / SMS OTP
  [ ] SSO (SAML / OIDC)

Generate session persistence? (SQLite via Mob.Repo) [Y/n]: y

This will create:
  lib/my_app/auth.ex              — Mob.Auth behaviour + strategy dispatch
  lib/my_app/screens/login.ex    — LoginScreen with selected providers
  lib/my_app/screens/register.ex — RegisterScreen (email+password only)
  priv/migrations/001_users.sql  — users table (if session persistence selected)
  config/mob.exs                 — injects auth config
```

**What it generates:**

- `LoginScreen` — pre-built screen with buttons for each selected provider, styled to platform conventions (Sign in with Apple button follows Apple HIG; Google button follows Material guidelines)
- `MyApp.Auth` module — thin wrapper around `Mob.Auth` that routes to the right strategy and handles token exchange with the developer's backend (stubbed out, ready to fill in)
- Session persistence schema if opted in — `users` table + `sessions` table via `Mob.Repo`
- Nav wiring — injects `reset_to(LoginScreen)` guard pattern into the root screen and a `logout/1` helper

**Supported strategies:**

- **Email + password** — standard login/register/forgot-password screens; developer supplies the backend verify endpoint
- **Sign in with Apple** — iOS: `ASAuthorizationAppleIDProvider`; Android: redirects to web OAuth (Apple doesn't provide a native Android SDK)
- **Google Sign-In** — Android: `play-services-auth`; iOS: `GoogleSignIn-iOS` SDK
- **Phone / SMS OTP** — Android: SMS Retriever API (auto-reads OTP, no permission); iOS: `ASAuthorizationPhoneNumberProvider`
- **SSO (SAML / OIDC)** — opens an in-app browser (`SFSafariViewController` / `CustomTabsIntent`) to the IdP; receives callback via deep link. Works with Okta, Auth0, Azure AD, Google Workspace, etc. Deep link scheme configured in `mob.exs`.

**Uniform Elixir API** (generated code calls these; underlying NIFs do the platform work):

```elixir
Mob.Auth.sign_in_with_apple(socket)
Mob.Auth.sign_in_with_google(socket)
Mob.Auth.sign_in_with_sso(socket, url: "https://login.corp.example.com/oauth/authorize?...")
Mob.Auth.sign_in_with_phone(socket, "+16045551234")

def handle_info({:auth, provider, %{token: jwt, ...}}, socket), do: ...
def handle_info({:auth, :cancelled}, socket), do: ...
def handle_info({:auth, :error, reason}, socket), do: ...
```

The generator is opinionated about the happy path but everything it produces is plain Elixir — developers can delete the generated screens and write their own, keeping just the `Mob.Auth` NIF calls.

### In-app purchases
- iOS: StoreKit 2 (`Product.purchase()`). Async purchase flow; `handle_info` delivers result.
- Android: Google Play Billing Library (`BillingClient`).
- Unified Elixir API: `Mob.IAP.products/2`, `Mob.IAP.purchase/2`, `Mob.IAP.restore/1`.
- Consumables, non-consumables, and subscriptions all handled via same call; type is in the product definition.
- Receipt validation (server-side) is out of scope — developer calls their own backend with the token.

```elixir
Mob.IAP.products(socket, ["premium_monthly", "lifetime_unlock"])
def handle_info({:iap, :products, products}, socket), do: ...

Mob.IAP.purchase(socket, "premium_monthly")
def handle_info({:iap, :purchased, %{product_id: id, token: t}}, socket), do: ...
def handle_info({:iap, :cancelled}, socket), do: ...
def handle_info({:iap, :error, reason}, socket), do: ...
```

### Ad integration
- iOS: Google Mobile Ads SDK (`GADMobileAds`). Banner (`GADBannerView`) and interstitial (`GADInterstitialAd`).
- Android: Google Mobile Ads SDK (`com.google.android.gms:play-services-ads`). Same ad unit types.
- `type: :ad_banner` component — renders a native banner ad view inline. Props: `ad_unit_id:`, `size: :banner | :large_banner | :medium_rectangle`.
- Interstitials triggered imperatively: `Mob.Ads.show_interstitial(socket, ad_unit_id: "...")`.
- Events: `{:ad, :loaded}`, `{:ad, :failed, reason}`, `{:ad, :closed}`, `{:ad, :impression}`.
- Initialisation: `Mob.Ads.init(socket, app_id: "ca-app-pub-xxx")` called once at mount.

### Crash reporting

Two distinct layers, each handling a different class of failure:

**BEAM-level crashes (pure Elixir)**

Most "crashes" in a Mob app are BEAM process exits with a structured reason and stacktrace — OTP gives you this for free. These can be captured without any native SDK:

- `Mob.Screen.terminate/2` is called on every screen process exit — hook in here to capture the reason + stacktrace
- OTP `Logger` already receives supervision tree crash reports as `:error` level messages — `Mob.NativeLogger` captures these natively, a crash reporter can also forward them
- A `Mob.CrashReporter` module (separate opt-in package) would collect these, batch them, and POST to a reporting backend over HTTP using `req` or `finch`

**Native crashes (NIF segfault, OOM kill, OS signal)**

These kill the process before the BEAM can do anything. Requires platform-native handling:

- iOS: `PLCrashReporter` (open source) or Firebase Crashlytics SDK. Signal handler writes a minidump; on next launch the app ships it.
- Android: `ApplicationExitInfo` API (Android 11+) lets you read the exit reason on next launch — covers ANRs and OOM kills without a separate SDK. For older Android + symbolicated native crashes, Crashlytics.

**Backend options (for BEAM-level reporting)**

- **Firebase Crashlytics** — free, dominant, good symbolication. Requires native SDKs on both platforms even for Elixir errors (SDK handles the upload transport). Adds native dependency weight.
- **Sentry** — has mobile SDKs but can also accept events via plain HTTP API. A self-hosted Sentry instance is achievable with Elixir and keeps all crash data on your own infrastructure. `mob_crash` (planned Hex package) would wrap the Sentry event ingest API — no native SDK needed for BEAM-level errors.
- **Custom backend** — `Mob.CrashReporter` posts structured JSON to any endpoint. Simplest for teams already running their own observability stack.

**Batteries-included goal**: `mob_crash` Hex package that works out of the box with zero config for self-hosted Sentry, and an escape hatch to configure any HTTP endpoint. Developer opts in by adding `mob_crash` to deps and calling `Mob.CrashReporter.start_link(dsn: "https://...")` in their application supervisor. No native SDK required for BEAM-level crash capture; native crash handling documented as a separate optional step.

---

### Named scroll containers + scroll events

**Problem:** Two `:scroll` nodes on the same screen have no way to be told apart, and the BEAM never hears about scroll position at all. This matters for: lazy-load triggers, hide-on-scroll headers, "back to top" buttons, analytics.

**Design:**

Add an `id` prop to `:scroll` (and generalise it as the standard identity mechanism across all interactive nodes):

```elixir
%{
  type: :scroll,
  props: %{id: :feed, on_scroll: {self(), :scrolled}},
  children: [...]
}
```

The BEAM receives scroll events as:

```elixir
def handle_info({:scroll, :feed, %{offset_y: 142.0, at_top: false, at_bottom: false}}, socket) do
  ...
end
```

**Payload fields:**

| Field | Type | Description |
|---|---|---|
| `offset_y` | float | Vertical scroll offset in dp/pts |
| `offset_x` | float | Horizontal scroll offset (for `axis: :horizontal` scrolls) |
| `at_top` | boolean | Offset ≤ threshold (e.g. 8dp) |
| `at_bottom` | boolean | Within threshold of the bottom |
| `velocity_y` | float | Optional — scroll velocity (useful for fling detection) |

**Implementation notes:**

- iOS: `ScrollView` doesn't expose offset natively in SwiftUI; use a `GeometryReader` + `PreferenceKey` trick or `UIScrollView` delegate via `UIViewRepresentable`
- Android: `LazyColumn` scroll state is readable via `LazyListState.firstVisibleItemScrollOffset`; `nestedScroll` modifier captures velocity
- Throttle events on the native side (e.g. every 16ms / 1 frame) before sending to BEAM — raw scroll events at 60fps would flood the mailbox
- `on_scroll` is opt-in; a `:scroll` with no `on_scroll` prop costs nothing

**Generalise `id` prop across all interactive nodes:**

Currently interactive nodes use `on_tap`/`on_change` tuple tags for routing. A first-class `id` prop would be cleaner and consistent — the `id` serves as the stable routing key, and the BEAM always knows which widget fired regardless of handle churn between renders.

**Platforms:** Both (Compose `LazyListState` / `ScrollState`; SwiftUI `ScrollViewReader` / `UIScrollView` delegate)

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
