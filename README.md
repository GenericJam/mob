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

### Deep links and constructed history

When arriving from a notification or external URL, you want a back stack even though the user didn't navigate there manually. `replace_stack` (planned) will allow constructing an arbitrary history:

```elixir
Mob.Socket.replace_stack(socket, [
  {:home_screen, %{}},
  {:list_screen, %{category: :recent}},
  {:detail_screen, %{id: 42}}   # becomes the active screen
])
```

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
