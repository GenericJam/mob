# Mob

A mobile framework for Elixir that runs the full BEAM runtime on-device — no server, no JavaScript, no React Native. Native UI driven directly from Elixir via NIFs.

> **Status:** Early development. Android emulator and iOS simulator working. Not yet ready for production use.

## What it does

Mob embeds OTP into your Android/iOS app and lets you write screens in Elixir using a LiveView-inspired lifecycle:

```elixir
defmodule MyApp.CounterScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :count, 0)}
  end

  def render(assigns) do
    %{
      type: :column,
      props: %{padding: 16},
      children: [
        %{type: :text,   props: %{text: "Count: #{assigns.count}"}, children: []},
        %{type: :button, props: %{text: "Increment", on_tap: self()}, children: []}
      ]
    }
  end

  def handle_event("tap", _params, socket) do
    {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
  end
end
```

- **Android:** native Views via JNI, no WebView
- **iOS:** UIKit via Objective-C NIFs, no WebView
- **State management:** `Mob.Screen` GenServer with `mount/3`, `render/1`, `handle_event/3`, `handle_info/2`
- **Boot time:** ~64ms to first Elixir line on iOS simulator (M4 Pro)

## Installation

```elixir
def deps do
  [
    {:mob, "~> 0.1.0"}
  ]
end
```

## Navigation

Mob has a built-in navigation stack managed inside the screen's GenServer. No separate navigator or router process is needed.

### Basic operations

Navigate from a `handle_event` or `handle_info` by returning a modified socket:

```elixir
# Push a new screen onto the stack
{:noreply, Mob.Socket.push_screen(socket, :detail_screen, %{id: 42})}

# Go back one screen (restores the previous socket state exactly)
{:noreply, Mob.Socket.pop_screen(socket)}

# Go back to a specific screen in the history
{:noreply, Mob.Socket.pop_to(socket, :menu_screen)}

# Go all the way back to the root screen
{:noreply, Mob.Socket.pop_to_root(socket)}

# Replace the entire stack with a fresh screen (no back button)
{:noreply, Mob.Socket.reset_to(socket, :home_screen, %{})}
```

Destinations are registered name atoms (`:detail_screen`) looked up via `Mob.Nav.Registry`, or full module atoms (`MyApp.DetailScreen`) used directly.

### How the stack works

The stack is a list of `{module, socket}` pairs stored in the GenServer state. `push` saves the current screen and mounts the new one. `pop` restores the previous screen's socket exactly as it was — no re-mount. `reset_to` clears the stack entirely and mounts fresh.

### Animated transitions

Set the transition before navigating; the platform UI animates accordingly:

| Transition | Animation |
|------------|-----------|
| `:push` | Slide in from right, old screen exits left |
| `:pop` | Slide in from left, old screen exits right |
| `:reset` | Cross-fade |
| `:none` | Instant (default) |

Mob.Screen sets the transition automatically based on the nav action — push uses `:push`, all pop variants use `:pop`, reset uses `:reset`.

### Hardware back gesture

Both platforms intercept the system back gesture automatically — no code needed in your screens.

- **Android**: the system back gesture (swipe from edge or hardware button) pops the nav stack. At the root screen (stack empty) the app is backgrounded via `moveTaskToBack(true)`.
- **iOS**: a left-edge swipe gesture on the hosting controller pops the nav stack. At the root screen it is a no-op — iOS apps background naturally via the home gesture, which is OS-controlled.

The gesture sends `{:mob, :back}` to the BEAM, which `Mob.Screen` intercepts before your `handle_info`. Your screens don't need to implement anything for this to work.

### Auth flow and the "home screen"

The bottom of the nav stack is the effective home screen — whatever was last passed to `reset_to`. After a successful login, call `reset_to(socket, MainScreen)` to zero the stack. The user can then press back repeatedly and will be backgrounded at the main screen, never returned to the login screen.

```elixir
# In your LoginScreen after successful auth:
{:noreply, Mob.Socket.reset_to(socket, MyApp.HomeScreen)}
```

### Deep links and constructed history

When arriving from a notification or external URL, you want a back stack even though the user didn't navigate there manually. `replace_stack` (planned) will allow constructing an arbitrary history:

```elixir
Mob.Socket.replace_stack(socket, [
  {:home_screen, %{}},
  {:list_screen, %{category: :recent}},
  {:detail_screen, %{id: 42}}   # becomes the active screen
])
```

## Display

### Safe area insets

Every screen automatically receives `assigns.safe_area` — a map with the size of the system-reserved zones in logical points (dp on Android, UIKit points on iOS):

```elixir
assigns.safe_area
# %{top: 62.0, bottom: 34.0, left: 0.0, right: 0.0}
```

| Key | What it covers |
|-----|---------------|
| `top` | Status bar + Dynamic Island / notch |
| `bottom` | Home indicator bar |
| `left` / `right` | Curved-edge insets (most devices: `0.0`) |

Values are `0.0` on devices without those features (older iPhones without a notch, most Androids). You get them for free — no opt-in needed.

**The framework does not insert any padding automatically.** Use the values however you like:

```elixir
def render(assigns) do
  safe_top    = trunc(assigns.safe_area.top)
  safe_bottom = trunc(assigns.safe_area.bottom)

  # Full-bleed header: colour fills behind the Dynamic Island,
  # text sits below it.
  %{type: :column, props: %{background: :blue_700}, children: [
    %{type: :spacer, props: %{size: safe_top}, children: []},
    %{type: :text,   props: %{text: "My App", padding: 16, ...}, children: []}
  ]}
end
```

Or add a plain spacer at the top and bottom of your scroll content if you just want the text to clear the system chrome.

## Live debugging

Mob supports full Erlang distribution so you can inspect and hot-push code to a running app without rebuilding.

### Setup

Add to your app's `start/0`:

```elixir
Mob.Dist.ensure_started(node: :"my_app@127.0.0.1", cookie: :my_cookie)
```

On iOS, distribution is started at BEAM launch via flags in `mob_beam.m`. On Android, `Mob.Dist` defers startup by 3 seconds to avoid a race with Android's hwui thread pool.

### Connect

Two named sessions are the standard: one for interactive use, one for agent/automated tasks.

```bash
# iOS simulator (no port forwarding needed)
./dev_connect.sh ios user
./dev_connect.sh ios agent

# Android emulator (sets up adb port forwarding automatically)
./dev_connect.sh android user
./dev_connect.sh android agent
```

Both connect to `mob_demo@127.0.0.1` with cookie `mob_secret`.

### What you can do once connected

```elixir
Node.list()   # confirm device node is visible

# Inspect live screen state
pid = :rpc.call(:"mob_demo@127.0.0.1", :erlang, :list_to_pid, [~c"<0.92.0>"])
:rpc.call(:"mob_demo@127.0.0.1", Mob.Screen, :get_socket, [pid])

# Hot-push a changed module (no rebuild needed)
mix compile && nl(MyApp.CounterScreen)
```

### EPMD tunneling

iOS simulator shares the Mac's network stack — no port setup needed.

Android uses `adb reverse tcp:4369 tcp:4369` so the Android BEAM registers in the Mac's
EPMD (not Android's), then `adb forward tcp:9100 tcp:9100` for the dist port. Both
platforms end up in the same EPMD. `dev_connect.sh` handles this automatically.

## OS debug tools

If you're coming from Elixir/backend land, the mobile toolchains have their own CLIs for talking to devices. Here's what's useful and what each thing does.

### Android — adb

`adb` (Android Debug Bridge) is the main CLI for talking to Android devices and emulators. It ships with Android Studio but you can also install it standalone (`brew install android-platform-tools`).

```bash
adb devices                          # list connected devices/emulators
adb -s emulator-5554 shell           # open a shell on a specific device
```

**Logs** — the equivalent of `tail -f` on your app's output:

```bash
adb logcat                           # everything (very noisy)
adb logcat -s Elixir                 # only Logger output from your BEAM code
adb logcat -s Elixir MobBeam MobNIF  # BEAM + native bridge logs
adb logcat -v time -s Elixir,MobBeam,MobNIF  # same, with timestamps
```

**File transfer:**

```bash
adb push local/path /data/local/tmp/file   # Mac → device
adb pull /data/local/tmp/file local/path   # device → Mac
```

**Port forwarding** — needed to connect Erlang distribution between Mac and Android emulator:

```bash
adb reverse tcp:4369 tcp:4369   # EPMD: Android BEAM registers in Mac's EPMD
adb forward tcp:9100 tcp:9100   # dist port: Mac can reach Android node
```

`mix mob.connect` runs these automatically.

**App lifecycle:**

```bash
adb shell am force-stop com.mob.demo        # kill the app entirely
adb shell input keyevent KEYCODE_HOME       # press home button (backgrounds app)
adb shell am start -n com.mob.demo/.MainActivity  # launch app
adb install path/to/app.apk                 # install an APK
```

**Battery info** (used by `mix mob.battery_bench`):

```bash
adb shell dumpsys battery                   # current battery state
adb shell dumpsys batterystats | grep "Charge counter"  # mAh counter
```

**Wireless ADB** — cut the USB cable once set up:

```bash
# While plugged in via USB:
adb -s SERIAL tcpip 5555             # switch device to TCP mode
adb connect 192.168.1.42:5555        # connect over WiFi
adb devices                          # confirm it shows up
```

### iOS — xcrun simctl

`xcrun simctl` is the CLI for the iOS Simulator. It's part of Xcode command-line tools (`xcode-select --install`).

```bash
xcrun simctl list devices            # list all simulators and their UDIDs
xcrun simctl list devices booted     # only the ones currently running
```

**Boot and open a simulator:**

```bash
xcrun simctl boot <UDID>                    # boot without opening the window
open -a Simulator                           # open the Simulator app window
```

**Logs** — streams NSLog / os_log output from your app:

```bash
xcrun simctl spawn booted log stream \
  --predicate 'process == "MobDemo"'        # only MobDemo output

# Save to file for later inspection:
xcrun simctl spawn booted log stream \
  --predicate 'process == "MobDemo"' > /tmp/mob.log &
```

**App lifecycle:**

```bash
xcrun simctl launch booted com.mob.demo     # launch app
xcrun simctl terminate booted com.mob.demo  # kill app (simulates backgrounding / force-quit)
xcrun simctl install booted path/to/App.app # install a built .app bundle
```

**Find app's data directory** (useful for reading crash dumps, finding BEAM files):

```bash
xcrun simctl get_app_container booted com.mob.demo data
# → /Users/you/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/...
```

**Privacy / permissions reset** (helpful when testing first-run flows):

```bash
xcrun simctl privacy booted reset all com.mob.demo
```

### Backgrounding the app from Elixir

Both platforms expose `Mob.Socket.exit_app/1` (planned) or you can call the NIF directly from IEx:

```elixir
# From an IEx session connected to the device:
:rpc.call(:"mob_demo_android@127.0.0.1", :mob_nif, :exit_app, [])
# Android: calls moveTaskToBack(true) — app goes to background, BEAM keeps running
# iOS: no-op — iOS apps background via the home gesture, which is OS-controlled
```

## Power benchmark

The BEAM's idle power draw on a real Android device is negligible when tuned correctly.
Use `mix mob.battery_bench` (from `mob_dev`) to measure battery drain for your app.

### Running a benchmark

```bash
# WiFi ADB setup (once, while plugged in):
adb -s SERIAL tcpip 5555
adb connect PHONE_IP:5555

# Run with defaults (Nerves-tuned BEAM, 30 min):
mix mob.battery_bench --device 192.168.1.42:5555

# Compare against no-BEAM baseline:
mix mob.battery_bench --no-beam --device 192.168.1.42:5555

# Try a specific preset:
mix mob.battery_bench --preset untuned   # raw BEAM, no tuning
mix mob.battery_bench --preset sbwt      # busy-wait disabled only
mix mob.battery_bench --preset nerves    # full Nerves set (same as default)

# Custom flags:
mix mob.battery_bench --flags "-sbwt none -S 1:1"

# Longer run for more accurate mAh resolution:
mix mob.battery_bench --duration 3600
```

### What the results mean

Example results on a Moto G phone (30-min screen-off run):

| Config          | mAh drain | mAh/hr |
|-----------------|-----------|--------|
| no-beam         | 100 mAh   | 200    |
| nerves (default)| 101 mAh   | 202    |
| untuned BEAM    | 125 mAh   | 250    |

The Nerves-tuned BEAM (`-S 1:1 -sbwt none +C multi_time_warp`) has essentially the same
idle power draw as a stock Android app. The overhead is in the noise for most workloads.
The untuned BEAM uses ~25% more power due to scheduler busy-waiting.

### Tuning flags

| Flag | Effect |
|------|--------|
| `-S 1:1 -SDcpu 1:1 -SDio 1` | Single scheduler — no cross-CPU wakeups |
| `-A 1` | Single async thread pool thread |
| `-sbwt none -sbwtdcpu none -sbwtdio none` | Disable busy-wait in all schedulers |
| `+C multi_time_warp` | Allow clock to jump forward; avoids spurious wakeups |

## Source

[github.com/genericjam/mob](https://github.com/genericjam/mob)
