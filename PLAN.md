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
- `moveTaskToBack` preferred over `finish()` — users expect apps to persist in the switcher.
- Dynamic home screen (login vs main) is a `reset_to` convention, not a framework feature.

### 4. `mix mob.deploy` → dist
**Goal:** Align implementation with architecture decision.
Currently `mix mob.deploy` (non-native) uses `adb push` / `cp`. Change it to compile + push via Erlang dist when a node is reachable. Keep adb push as fallback for when dist isn't up.

### 5. `mix mob.watch` in mob_dev dashboard
**Goal:** "Push on save" toggle in the web UI — same logic as `mix mob.watch` but driven from the server.
- `MobDev.Server.WatchWorker` GenServer — wraps the watch loop
- Toggle switch in dashboard header starts/stops it
- Status indicator: last push time, module count, errors

### 6. KitchenSink screen
All Phase 1 components exercised in one demo screen: `column`, `row`, `scroll`, `text`, `button`, `text_field`, `toggle`, `slider`, `divider`, `spacer`.
Depends on: styling system (item 1) + event model extension (item 2).

---

## Phase 2 roadmap

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

### Physical device support
- **Android wireless**: already works via USB adb; wireless reconnect via dist (no extra work needed after ARCHITECTURE.md flow)
- **iOS physical**: needs `iproxy` USB tunneling (libimobiledevice) for dist port forwarding

### lazy_list
`<.lazy_list items={@items}>` — renders only visible items. `on_end_reached` event for infinite scroll. NIF side: RecyclerView scroll state listener.

### Push notifications
`mob_push` package. FCM (Android) / APNs (iOS). Registration token + `handle_info({:notification, payload}, socket)`. `Mob.Permissions.request(:notifications, socket)`.

### Offline / local storage
SQLite via NIF. `Mob.Repo` with Elixir schema + migrations on app start. WAL mode default.

### App Store / Play Store build pipeline
`mix mob.release --platform android|ios` — Gradle/Xcode build, signing, `.aab` / `.ipa` output. Fastlane for upload.

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
