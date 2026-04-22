# Mob — Agent Instructions

See [`guides/agentic_coding.md`](guides/agentic_coding.md) for a full guide on the
agent round-trip workflow: how to connect to the running Erlang node, when to use
`Mob.Test` vs MCP platform tools, and how to avoid the instinct to reach for
`xcrun simctl` screenshots.

---

## Native App Test Harness — Vision

### What mob is (beyond the UI framework)

Mob has two modes of use:

1. **Mob UI apps** — Elixir-driven SwiftUI/Android apps. The BEAM renders the UI.
2. **Native sidecar** — The BEAM runs invisibly inside any native Xcode/Android Studio
   app as a debug-only test and agent harness. The native app has zero Elixir dependency.
   In production builds the BEAM is stripped entirely.

The sidecar mode is the long-term bet. It gives native developers (who write zero Elixir)
a way to let agents introspect and drive their apps during development and CI — without
changing how they build or ship.

### The cocoon model

The BEAM + NIF wraps the native app completely. From the OS's perspective, there is one
process: the native app. The BEAM runs on a background thread. The NIF, being in-process,
has privileges no external tool has:

- Direct access to the iOS/Android UI object graph (no accessibility bridge latency)
- Ability to intercept and synthesize touch events before they reach the app
- Access to non-UI state: model objects, view controller hierarchy, memory
- Faster and more reliable than Appium, XCUITest, or `xcrun simctl` — no IPC round-trip

The end goal is that the BEAM is **the whole world to this app**: it can observe every
touch, inject synthetic touches, read every visible label, and report full UI state — all
over Erlang distribution to a remote test runner or agent.

### Why BEAM / why not XCUITest

- XCUITest runs out-of-process and requires a separate test host target — it cannot read
  in-memory model state, only rendered accessibility output
- Appium adds an HTTP layer and has significant latency
- The BEAM runs in-process with sub-millisecond IPC via Erlang distribution
- Tests can be written in any language that speaks Erlang distribution (Elixir, Erlang,
  or via the distribution protocol directly)
- Hot code push means test logic can be updated without restarting the app or rebuilding

### Development phases

**Phase 1 — Attachment and reporting (complete)**

- `ui_tree/0` — walks `UIApplication.shared` windows via UIAccessibility APIs, returns
  `[{type, label, value, {x,y,w,h}}, ...]` tuples. Works on any app with zero modification.
- `ui_debug/0` — raw accessibility dump for debugging

**Phase 2 — Synthetic interaction (complete)**

- `tap/1` — tap by accessibility label
- `tap_xy/2` — tap at screen coordinates (with responder-chain walk to focus text fields)
- `type_text/1` — type into the focused text field
- `delete_backward/0`, `key_press/1`, `clear_text/0` — keyboard control
- `long_press_xy/3`, `swipe_xy/4` — gesture synthesis

**Phase 3 — Full cocoon / event interception (future)**

Intercept the touch event stream before it reaches the app's responder chain. The BEAM
decides whether to pass events through, suppress them, or inject new ones. At this point
the BEAM is the authoritative input source and the app is fully contained.

---

## inject / eject — native project integration

For native-only developers (no Elixir, just Xcode or Android Studio), mob is added and
removed as a debug sidecar via a single command. The production app is never affected.

```bash
mix mob.inject MyApp.xcodeproj   # add sidecar to Xcode project (one time)
mix mob.eject  MyApp.xcodeproj   # remove it cleanly — git diff shows nothing
```

### What inject does (iOS)

- Adds `mob_nif.m`, `mob_beam.m` as Debug-only compile sources
- Links `libbeam.a` and supporting static libs as Debug-only
- Copies ERTS runtime directory as a Debug-only bundle resource
- Adds `#if DEBUG mob_start_beam() #endif` to AppDelegate/SceneDelegate

### What inject does (Android)

```gradle
// build.gradle (app) — added by inject
debugImplementation 'io.mob:sidecar:VERSION'
```

```kotlin
// Application.onCreate() — added by inject
if (BuildConfig.DEBUG) MobSidecar.start(this)
```

(The `Application.onCreate` line can be eliminated with a ContentProvider auto-init,
making Android injection truly zero-touch.)

### eject guarantee

`eject` is a clean inverse. `git diff` after eject shows nothing meaningful. This is
important for the trust model — a developer can verify mob leaves no footprint.

**Status:** `inject`/`eject` are planned; pre-built `libbeam.a` fat binary (simulator +
device + Android) is the prerequisite.

---

## MCP server — `mob_mcp` (planned)

### Design intent

The MCP server is an abstraction layer between the agent and the BEAM. The agent
never sees Erlang nodes, distribution, or NIF calls directly — it talks to typed
tools that happen to be backed by the BEAM internally.

**The abstraction is the point.** A developer using mob with an agent should not be
able to accidentally write Elixir, because no tool exists to do so. The agent has
everything it needs to verify and drive the native app, and nothing that lets it reach
into the BEAM layer.

### Package split

```
mob_dev   — Mix tasks: deploy, connect, push, doctor, new, inject, eject
mob_mcp   — MCP server: native-mode tools for agent-driven development
```

`mob_mcp` depends on `mob_dev` for device discovery and tunnel setup.
`mob_dev` has no knowledge of MCP. Clean dependency direction.

### Single mode

The MCP server has one mode. There is no `MOB_MODE=elixir`. If a developer
wants full BEAM access they open IEx directly — that is a human workflow,
not an agent workflow. Giving the agent an Elixir-level tool would just be
a worse IEx with predefined functions.

### Tools exposed

| Tool | Backed by |
|------|-----------|
| `mob_deploy` | `mix mob.deploy --native` |
| `mob_build` | `xcodebuild` / `gradlew assembleDebug` + `simctl install` |
| `mob_ui_tree` | `mob_nif:ui_tree/0` via RPC |
| `mob_tap` | `mob_nif:tap_xy/2` via RPC (finds by label internally) |
| `mob_type_text` | `mob_nif:type_text/1` via RPC |
| `mob_swipe` | `mob_nif:swipe_xy/4` via RPC |
| `mob_screenshot` | `xcrun simctl io` / adb screencap |
| `mob_logs` | simulator console / adb logcat |
| `mob_assert_visible` | `ui_tree` + label/value match |
| `mob_wait_for` | poll `ui_tree` with timeout + backoff |

### Agent loop for native-only projects

```
1. edit Swift/Kotlin files (appear in Xcode/AS immediately)
2. mob_build  → xcodebuild + simctl install
3. mob_ui_tree → confirm screen state
4. mob_tap / mob_type_text → drive interactions
5. repeat
```

The developer sees all code changes in their IDE in real time and can intervene at
any point. They never need to touch the terminal or know Erlang exists.

### Project integration

`mix mob.new` and `mix mob.inject` both emit `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "mob": {
      "command": "mix",
      "args": ["mob_mcp.server"]
    }
  }
}
```

Every developer and every agent session gets the same tools automatically.
No per-session setup required.

---

## iOS accessibility activation

SwiftUI lazily populates its accessibility tree only when an accessibility service is
active. Run this once per simulator session before calling `ui_tree`:

```bash
UDID=<booted-simulator-udid>
xcrun simctl spawn $UDID defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool YES
xcrun simctl spawn $UDID notifyutil -p com.apple.accessibility.voiceover.status.changed
```

Wait ~500ms for propagation. Survives app restarts within the same simulator session.

**TODO:** `mix mob.connect` should run this automatically for iOS simulator targets.

---

## Standard debugging workflow

The preferred tool is `mix mob.connect` (from `mob_dev` package):

```bash
cd ~/code/mob_demo
mix mob.connect          # discover all devices, tunnel, restart, connect IEx
mix mob.connect --no-iex # same but print node names instead of starting IEx
mix mob.devices          # list connected devices and their status
```

Node names are platform-specific:
- iOS simulator:    `mob_demo_ios@127.0.0.1`
- Android emulator: `mob_demo_android@127.0.0.1`

### EPMD tunneling

iOS simulator shares the Mac's network stack — the iOS BEAM registers directly in
the Mac's EPMD on port 4369. No forwarding needed.

Android is a separate network namespace. `mob_dev` sets up adb tunnels automatically:

```
adb reverse tcp:4369 tcp:4369   # EPMD: device → Mac (Android BEAM registers in Mac EPMD)
adb forward tcp:9100 tcp:9100   # dist:  Mac → device
```

### Port assignment (handled by mob_dev)

Devices are assigned dist ports by index to avoid conflicts:
- Device 0 (Android): port 9100
- Device 1 (iOS sim): port 9101

iOS dist port is passed via `SIMCTL_CHILD_MOB_DIST_PORT` env var; `mob_beam.m` reads
`MOB_DIST_PORT` at startup. Android dist port is passed as an intent extra (`mob_dist_port`);
**`MainActivity.java` does NOT yet read this — multi-Android support is pending.**

Both iOS and Android end up registered in the same Mac EPMD. `mix mob.connect` sets
up all tunnels automatically.

## Day-to-day development loop

```bash
# Edit Elixir code, then:
mix mob.deploy          # compile + push BEAMs + restart apps
mix mob.connect         # tunnel + wait for nodes + drop into IEx

# In IEx (after mob.connect):
mix compile && nl(MobDemo.CounterScreen)   # hot-push one module without restart
Node.list()                                # verify both devices connected
:rpc.call(:"mob_demo_android@127.0.0.1", MobDemo.CounterScreen, :some_fn, [])
```

### Reading live screen state

```elixir
# Screen pid is logged at app start: "[mob] step 5 => {ok,<0.92.0>}"
pid = :rpc.call(:"mob_demo_android@127.0.0.1", :erlang, :list_to_pid, [~c"<0.92.0>"])
socket = :rpc.call(:"mob_demo_android@127.0.0.1", Mob.Screen, :get_socket, [pid])
socket.assigns   # live assigns
```

### Hot code push

```bash
# After editing a screen (from the terminal):
mix mob.push          # compile + push all changed modules to all connected devices
mix mob.push --all    # force-push every module

# Or from inside IEx (after mob.connect), one module at a time:
nl(MobDemo.CounterScreen)
# Returns: {:ok, [{:"mob_demo@127.0.0.1", :loaded, MobDemo.CounterScreen}]}
```

### Android distribution

Android cannot start distribution at BEAM launch (races with hwui thread pool, causes
SIGABRT via FORTIFY `pthread_mutex_lock on destroyed mutex`). Instead, `Mob.Dist.ensure_started/1`
defers `Node.start/2` by 3 seconds after app startup. This is handled in the mob library —
app code just calls `Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1", cookie: :my_secret)`.

ERTS helper binaries (`erl_child_setup`, `inet_gethost`, `epmd`) cannot be exec'd from the
app data directory (SELinux `app_data_file` blocks `execute_no_trans`). They are packaged in
the APK as `lib*.so` in `jniLibs/arm64-v8a/` (gets `apk_data_file` label, which allows exec).
`mob_beam.c` symlinks `BINDIR/<name>` → `<nativeLibraryDir>/lib<name>.so` before `erl_start`.

## Agent round-trip workflow

The standard loop for AI-assisted feature development or debugging. Use all three
layers in order — BEAM state first, then visual verification only when needed.

### 1. Edit and deploy

```bash
mix mob.push            # compile + push changed BEAMs to all connected nodes
# or for a native rebuild (e.g. after NIF or Swift/Kotlin change):
mix mob.deploy --native
```

### 2. Inspect BEAM state via IEx or Mob.Test

Connect (or use an already-open IEx session from `mix mob.connect`):

```bash
mix mob.connect --no-iex   # sets up tunnels, prints node names, exits
```

Then from a separate IEx session or script:

```elixir
node = :"mob_demo_ios@127.0.0.1"
Mob.Test.screen(node)    # which screen is showing?
Mob.Test.assigns(node)   # live assigns — count, selected items, etc.
Mob.Test.tap(node, :some_button)   # drive a tap programmatically
Mob.Test.find(node, "Submit")      # locate a widget by visible text
```

This is the fastest path. BEAM state is exact and doesn't require image decoding.

### 3. Visual verification via MCP tools

When you need to confirm rendering, layout, or animations — use the platform MCP
servers. These are available as tools in the agent environment.

**iOS Simulator** (`mcp__ios-simulator__*`):

| Tool | When to use |
|------|-------------|
| `screenshot` | Capture the current simulator frame |
| `ui_tap` | Tap at x,y coordinates |
| `ui_type` | Type text into focused input |
| `ui_swipe` | Swipe gesture |
| `ui_view` | Inspect the accessibility tree |
| `ui_describe_point` | What element is at this coordinate? |
| `ui_describe_all` | Full accessibility dump |
| `record_video` / `stop_recording` | Record an interaction sequence |

**Android** (`mcp__adb__*`):

| Tool | When to use |
|------|-------------|
| `dump_image` | Screenshot from the connected device/emulator |
| `inspect_ui` | XML accessibility dump of the current view |
| `adb_shell` | Run arbitrary shell commands on the device |
| `adb_logcat` | Tail logcat (Elixir logs appear under the `Elixir` tag) |

### Typical round-trip

```
1. Edit Elixir code
2. mix mob.push
3. Mob.Test.screen(node)   ← confirm navigation / state
4. mcp__ios-simulator__screenshot  ← visual sanity check
5. Mob.Test.tap(node, :button)     ← drive interaction
6. Mob.Test.assigns(node)  ← confirm state updated correctly
7. repeat
```

Use `Mob.Test` for assertions (exact, fast, no image parsing). Use MCP screenshot/UI
tools for layout checks, animation spot-checks, or when a bug is only visible
in the rendered output.

## Device automation with Mob.Test

After connecting via `mix mob.connect`, use `Mob.Test` to inspect and drive the
running app without touching the native UI. Prefer this over screenshot-based
inspection — it gives exact state, not a visual approximation.

```elixir
node = :"mob_demo_ios@127.0.0.1"   # or mob_demo_android@127.0.0.1

# What screen is showing and what state is it in?
Mob.Test.screen(node)    #=> MobDemo.NavScreen
Mob.Test.assigns(node)   #=> %{depth: 0, safe_area: %{top: 62.0, ...}}

# Find a node by visible text
Mob.Test.find(node, "Device APIs")
#=> [{[0, 0, 9], %{"type" => "button", ...}}]

# Trigger a tap by the tag atom used in on_tap: {self(), tag}
Mob.Test.tap(node, :open_device)

# Full snapshot for debugging
Mob.Test.inspect(node)
# %{screen: MobDemo.NavScreen, assigns: ..., nav_history: [...], tree: ...}
```

Tag atoms come from `on_tap: {self(), :tag_atom}` in the render tree. Check the
screen's `render/1` to find them. After a tap, call `Mob.Test.screen/1` again to
confirm the navigation happened.

## Running tests

```bash
mix test          # from ~/code/mob
```

### Onboarding integration tests

The `test/onboarding/` suite verifies the full first-run flow end-to-end: archive
install, project generation, `mix mob.install`, `mix mob.doctor`, and failure modes.
These tests are **excluded from `mix test` by default** (they take minutes and require
Hex/network access). Run them explicitly:

```bash
# Fast subset — no simulator needed (~3 min, suitable for PR gating)
MIX_ENV=test mix test --only generator

# Failure-mode checks — no simulator needed (~2 min)
MIX_ENV=test mix test --only pre_device

# Everything above in one pass
MIX_ENV=test mix test --only onboarding

# Full suite including post-device tests (requires a booted iOS simulator)
MIX_ENV=test mix test --only failure_modes
```

Run one file at a time with `--max-cases 1` to avoid workspace ID collisions between
concurrent tests:

```bash
MIX_ENV=test mix test test/onboarding/generator_test.exs --only generator --max-cases 1
MIX_ENV=test mix test test/onboarding/failure_modes_test.exs --only pre_device --max-cases 1
```

**What they test:**

| Tag | File | Covers |
|-----|------|--------|
| `:generator` | `generator_test.exs` | Archive install, `mix mob.new`, `mix mob.install`, `mix mob.doctor` |
| `:pre_device` | `failure_modes_test.exs` | Failure modes that don't need a running simulator |
| `:post_device` | `failure_modes_test.exs` | Failures requiring a live iOS simulator |

**Preserved workspaces:** When a test fails, its workspace is kept at
`/tmp/mob_onboarding/run_<PID>/<test_id>/`. Inspect `logs/` for per-step output.
Workspaces from passing tests are deleted automatically.

**Known limitations (published `mob_dev 0.1.7`):**

- `MOB_OTP_BASE_URL` is not respected — OTP download URL cannot be overridden for
  failure injection. Network failure tests verify OTP reporting format instead.
- `check_elixir` reads `System.version()` (the running BEAM) — PATH-based fake Elixir
  versions have no effect. The Elixir version test verifies the check produces clear output.
- `check_java` ignores exit code (`{out, _}` pattern) — a fake java always shows ✓.
  The java test verifies the check is present and reports useful version info.
- `xcrun` and `java` share `/usr/bin` with `dirname`/`basename` used by mise/asdf elixir
  launcher scripts. Filtering `/usr/bin` from PATH crashes the subprocess. Tests for these
  tools verify the success path format instead of injecting a missing-tool failure.

## Common pitfalls

See [`common_fixes.md`](common_fixes.md) for a running log of diagnosed bugs and their
fixes — consult it first when hitting silent crashes or unexpected BEAM behavior.

## User issues log

See [`user_issues.md`](user_issues.md) for a record of real issues encountered by
beta users, their root causes, and fixes applied. Read this before working on setup,
deployment, or tooling problems — the same issues recur, especially for Nix users.
User alias "Nova" = macOS + Nix-managed toolchain throughout.

## Key files

- `lib/mob/screen.ex` — GenServer wrapper, lifecycle callbacks
- `lib/mob/socket.ex` — assigns + internal mob state
- `lib/mob/renderer.ex` — walks component tree, issues NIF calls
- `lib/mob/dist.ex` — platform-aware distribution startup
- `src/mob_nif.erl` — Erlang NIF stub (declares all NIF functions)
- `ios/mob_nif.m` — iOS NIF implementation (SwiftUI bridge + test harness)
- `android/jni/mob_nif.c` — Android NIF implementation (JNI bridge)
- `ios/mob_beam.m` — iOS BEAM launcher
- `android/jni/mob_beam.c` — Android BEAM launcher
