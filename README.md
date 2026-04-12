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

## Source

[github.com/genericjam/mob](https://github.com/genericjam/mob)
