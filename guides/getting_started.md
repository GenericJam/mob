# Getting Started

This guide walks you through creating a new Mob app from scratch, running it on a simulator, and making your first code change with hot push.

## Prerequisites

- Elixir 1.18 or later (with Hex: `mix local.hex`)
- `mob_new` installed globally: `mix archive.install hex mob_new`
- For iOS: Xcode 15+ with the iOS Simulator
- For Android: Android Studio Hedgehog or later with an AVD (Android Virtual Device) configured

## Create a new app

```bash
mix mob.new my_app
cd my_app
```

`mix mob.new` generates a complete project: Elixir sources, a native iOS project, and a native Android project. The Elixir code lives in `lib/`; native projects live in `ios/` and `android/`.

## Project structure

```
my_app/
├── lib/
│   ├── my_app.ex          # Mob.App entry point
│   └── my_app/
│       └── home_screen.ex # Your first screen
├── ios/
│   └── build.sh           # iOS build script
├── android/
│   └── app/               # Android project
└── mix.exs
```

## Install dependencies

```bash
mix mob.install
```

This fetches Elixir dependencies and downloads the pre-built OTP runtime for your target platform(s). The OTP download is platform-specific (iOS simulator or Android ARM64) and may take a few minutes the first time.

## Verify your environment

```bash
mix mob.doctor
```

`mix mob.doctor` checks that every required tool is installed, your `mob.exs` is correctly configured, the OTP runtimes were downloaded and extracted properly, and at least one device or simulator is visible. Run it any time something isn't working — it prints specific fix instructions for each issue it finds:

```
=== Mob Doctor ===

Tools
  ✓ Elixir — 1.18.3
  ✓ OTP — 28 (ERTS 16.3)
  ✓ Hex — 2.1.1
  ✓ adb — /usr/bin/adb
  ✓ xcrun — Xcode 15.4 Build version 15F31d
  ✓ java — openjdk version "21.0.2" 2024-01-16
  ✓ Android SDK — /Users/you/Library/Android/sdk
  ✓ python3 — /usr/bin/python3
  ✓ rsync — /usr/bin/rsync
  ⚠ ideviceinfo — not found (optional, needed for iOS physical device battery benchmarks)
      brew install libimobiledevice

Project
  ✓ mob.exs — found
  ✓ mob_dir — /Users/you/code/mob

Build
  ✓ mix deps — 42 deps fetched
  ✓ compiled — 680 BEAMs in 12 lib(s)

OTP Cache
  ✓ OTP Android — otp-android-73ba6e0f (erts-16.3)
  ✓ OTP iOS simulator — otp-ios-sim-73ba6e0f (erts-16.3)

Devices
  ✓ Android devices — Pixel 8 (emulator-5554)
  ✓ iOS simulator — iPhone 16 Pro (A1B2-...)

1 warning — optional items above may limit some features.
```

If `mix mob.doctor` shows failures, fix them before continuing. See [Troubleshooting](troubleshooting.md) for detailed solutions.

## Run on simulator / emulator

`mix mob.deploy` compiles your Elixir code and pushes it to the running app. With `--native` it also rebuilds and reinstalls the full native binary. Without `--native` it pushes only the changed .beam files — no rebuild required.

Use `--ios` or `--android` to target a single platform; omit both to deploy to all connected devices.

> **Physical devices:** Android devices must have Developer Options and USB Debugging enabled and be connected via USB for the initial deploy. After the first install, wireless debugging works. iOS is similar — trust the Mac on first connection.

### iOS simulator

```bash
mix mob.deploy --native --ios
```

Or open `ios/` in Xcode, select a simulator, and press Run.

### Android emulator

```bash
mix mob.deploy --native --android
```

Or open the `android/` folder in Android Studio and press Run.

## Use the dev server for live debugging

```bash
iex -S mix mob.server
```

Without `iex`:

```bash
mix mob.server
```

This starts the Mob dev server and opens a dashboard at `http://localhost:4040`.

The dashboard shows each connected device (Android emulator and iOS simulator side by side), with **Update** and **First Deploy** buttons for each. Below the device cards is a live log panel that streams BEAM output from every connected device in real time — useful for watching startup, crashes, and `IO.inspect` output without leaving the browser.

![Mob Dev dashboard showing two connected devices and live BEAM logs](../assets/mob_dev_dashboard.png)

## Connect a live IEx session

Once the app is running:

```bash
mix mob.connect
```

This tunnels EPMD, sets up Erlang distribution, and drops you into an IEx session connected to the running BEAM node on the device. You can inspect state, call functions, and push code changes without restarting the app.

```elixir
# Verify the device node is visible
Node.list()
#=> [:"my_app_ios@127.0.0.1"]

# Inspect the current screen's assigns
Mob.Test.assigns(:"my_app_ios@127.0.0.1")
#=> %{safe_area: %{top: 62.0, ...}}
```

## Hot-push a code change

Edit a screen module, then push the new bytecode to the running app without restarting:

```bash
mix mob.push
```

`mix mob.push` compiles your project and loads every changed module into the live BEAM on all connected devices — no app restart. The screen updates instantly.

Use `mix mob.push --all` to force-push every module rather than just those that changed.

## Deployment reference

There are several ways to get code onto a device. Each one has a different scope and mechanism — here's how they fit together:

| Command | Restarts app? | Requires dist? | What it does |
|---------|:---:|:---:|---|
| `mix mob.deploy --native` | Yes | No | Build native binary + install APK/IPA + push .beam files |
| `mix mob.deploy` | Yes | No | Push .beam files + restart app (falls back to adb/simctl if dist unavailable) |
| `mix mob.push` | No | **Yes** | Hot-push changed .beam files via RPC — preserves all app state |
| `mix mob.watch` | No | **Yes** | Same as `mob.push`, triggered automatically on file save |
| `nl(MyApp.Screen)` in IEx | No | **Yes** | Hot-push a single module from an IEx session |

**Requires dist** means the app must already be running with Erlang distribution active. Run `mix mob.connect` first or use the dashboard's **Watch** button — both establish the distribution connection.

### Which one should I use?

- **First time running the app, or changed native code (Swift/Kotlin/C)?**
  → `mix mob.deploy --native`

- **Changed Elixir code and want a clean restart?**
  → `mix mob.deploy`

- **Changed Elixir code and want to keep app state (fastest)?**
  → `mix mob.push` (requires the app to be running with dist active)

- **Want changes pushed automatically while you edit?**
  → Enable Watch in the dev dashboard, or run `mix mob.watch`

- **Already in IEx and want to push one module?**
  → `nl(MyApp.Screen)` — same underlying RPC, no shell required

### Under the hood

`mix mob.deploy` uses `adb push` (Android) or `simctl` (iOS) to copy .beam files into the app bundle, then restarts the app. No live connection required.

`mix mob.push` and `nl/1` both use Erlang distribution: they call `:code.load_binary/3` on the device node via RPC, replacing the running module in-place — exactly like hot code loading in a production release. The running process state is untouched. This is the fastest path: sub-second for a single module.

## Your first screen

A screen module looks like this:

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :count, 0)}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={24} gap={16}>
      <Text text={"Count: #{assigns.count}"} text_size={:xl} />
      <Button text="Tap me" on_tap={tap(:increment)} />
    </Column>
    """
  end

  def handle_info({:tap, :increment}, socket) do
    {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
```

`mount/3` initialises assigns. `render/1` returns the component tree via the `~MOB` sigil (imported automatically by `use Mob.Screen`). `handle_info/2` updates assigns in response to user interaction. After each callback that returns a modified socket, the framework calls `render/1` again and pushes the diff to the native layer.

## App entry point

Your app module declares navigation and starts the root screen:

```elixir
defmodule MyApp do
  use Mob.App

  def navigation(_platform) do
    stack(:home, root: MyApp.HomeScreen)
  end

  def on_start do
    Mob.Screen.start_root(MyApp.HomeScreen)
  end
end
```

`use Mob.App` generates a `start/0` entry point that the BEAM launcher calls. It handles framework initialization (logger, navigation registry) before calling your `on_start/0`.

## Next steps

- [Screen Lifecycle](screen_lifecycle.md) — understand mount, render, handle_event, handle_info
- [Components](components.md) — the full component reference
- [Navigation](navigation.md) — stack, tab bar, drawer, push/pop
- [Theming](theming.md) — color tokens, named themes, runtime switching
- [Data & Persistence](data.md) — `Mob.State` for app preferences, Ecto + SQLite for structured data
- [Device Capabilities](device_capabilities.md) — camera, location, haptics, notifications
- [Testing](testing.md) — unit tests and live device inspection
- [Troubleshooting](troubleshooting.md) — if something isn't working, start here
