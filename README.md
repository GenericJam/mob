# Mob

BEAM-on-device mobile framework for Elixir. OTP runs inside your iOS and Android apps — embedded directly in the app bundle, no server required. Screens are GenServers; the UI is rendered by Compose and SwiftUI via a thin NIF.

[![Hex.pm](https://img.shields.io/hexpm/v/mob.svg)](https://hex.pm/packages/mob)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/mob)

> **Status:** Early development. Android emulator and iOS simulator confirmed working. Not yet ready for production use.

## What it is

```
Your Elixir app (GenServers, OTP supervision, pattern matching, pipes)
          ↓
     Mob.Screen  (GenServer — your logic lives here)
          ↓
    Mob.Renderer  (component tree → JSON → NIF call)
          ↓
Compose (Android)   SwiftUI (iOS)   ← native rendering, native gestures
```

You write Elixir. The native layer handles rendering. The BEAM node runs on the device — connect your dev machine to the running app over Erlang distribution, inspect state, and hot-push new bytecode without a restart.

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:mob, "~> 0.5"}]
end
```

The `mob_new` package (separate) provides project generation, deployment tooling, and will import `mob_dev` which is a live dashboard. Install it as a Mix archive:

```bash
mix archive.install hex mob_new
```

## A screen

```elixir
defmodule MyApp.CounterScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :count, 0)}
  end

  def render(assigns) do
    %{
      type: :column,
      props: %{padding: :space_md, gap: :space_md, background: :background},
      children: [
        %{type: :text,   props: %{text: "Count: #{assigns.count}", text_size: :xl, text_color: :on_background}, children: []},
        %{type: :button, props: %{text: "Increment", on_tap: {self(), :increment}}, children: []}
      ]
    }
  end

  def handle_event("tap", %{"tag" => "increment"}, socket) do
    {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
  end
end
```

## App entry point

```elixir
defmodule MyApp do
  use Mob.App, theme: Mob.Theme.Obsidian

  def navigation(_platform) do
    stack(:home, root: MyApp.CounterScreen)
  end

  def on_start do
    Mob.Screen.start_root(MyApp.CounterScreen)
    Mob.Dist.ensure_started(node: :"my_app@127.0.0.1", cookie: :secret)
  end
end
```

## Navigation

```elixir
# Push a new screen
Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{id: 42})

# Pop back
Mob.Socket.pop_screen(socket)

# Tab bar layout
tab_bar([
  stack(:home,    root: MyApp.HomeScreen,    title: "Home"),
  stack(:profile, root: MyApp.ProfileScreen, title: "Profile")
])
```

## Theming

```elixir
# Named theme
use Mob.App, theme: Mob.Theme.Obsidian

# Override individual tokens
use Mob.App, theme: {Mob.Theme.Obsidian, primary: :rose_500}

# From scratch
use Mob.App, theme: [primary: :emerald_500, background: :gray_950]

# Runtime switch (accessibility, user preference)
Mob.Theme.set(Mob.Theme.Citrus)
```

Built-in themes: `Mob.Theme.Obsidian` (dark violet), `Mob.Theme.Citrus` (warm charcoal + lime), `Mob.Theme.Birch` (warm parchment).

## Device APIs

All async — call the function, handle the result in `handle_info/2`:

```elixir
# Haptic feedback (synchronous — no handle_info needed)
Mob.Haptic.trigger(socket, :success)

# Camera
Mob.Camera.capture_photo(socket)
def handle_info({:camera, :photo, %{path: path}}, socket), do: ...

# Location
Mob.Location.start(socket, accuracy: :high)
def handle_info({:location, %{lat: lat, lon: lon}}, socket), do: ...

# Push notifications
Mob.Notify.register_push(socket)
def handle_info({:push_token, :ios, token}, socket), do: ...
```

Also: `Mob.Clipboard`, `Mob.Share`, `Mob.Photos`, `Mob.Files`, `Mob.Audio`, `Mob.FoundationModels`, `Mob.Vision`, `Mob.Speech`, `Mob.Motion`, `Mob.Biometric`, `Mob.Scanner`, `Mob.Permissions`.

## What's in the box

The pre-built OTP runtime that ships with each app includes:

- **Real `:crypto`** — OpenSSL 3.x, statically linked into the app's
  native lib. ECDH (incl. x25519, secp256r1), AEAD (ChaCha20-Poly1305,
  AES-GCM), SHA-2 hashes, HMAC, PBKDF2, HKDF, real `strong_rand_bytes/1`.
  No insecure shim, no dlopen.
- **`:public_key` + `:ssl`** — cert parsing, HTTPS clients,
  TLS sockets. The whole standard `:ssl` API is available.
- **Phoenix-compatible** — Phoenix, LiveView, plug_crypto, jose, joken,
  guardian, oban, and anything else using `:crypto`/`:ssl` works
  unmodified.
- **Erlang distribution** — `mix mob.connect` opens an IEx session
  on-device. Hot-push individual modules with `nl/1`.

Native APIs surfaced via `Mob.*` modules (above) cover camera,
location, audio, files, biometrics, push, clipboard, share, scanner,
Foundation Models, Vision, Speech,
motion sensors, permissions.

The OTP runtime tarball is ~80 MB compressed; sliced per-arch by
App Thinning (iOS) and App Bundle (Android) so each user only
downloads ~25 MB of native runtime, on top of the BEAM bytecode for
your app.

## Live development

```bash
mix mob.connect          # tunnel + connect IEx to running device
nl(MyApp.SomeScreen)     # hot-push new bytecode, no restart

# In IEx:
Mob.Test.screen(:"my_app_ios@127.0.0.1")  #=> MyApp.CounterScreen
Mob.Test.assigns(:"my_app_ios@127.0.0.1") #=> %{count: 3, ...}
Mob.Test.tap(:"my_app_ios@127.0.0.1", :increment)
```

## Testing

```elixir
test "increments count" do
  {:ok, pid} = Mob.Screen.start_link(MyApp.CounterScreen, %{})
  :ok = Mob.Screen.dispatch(pid, "tap", %{"tag" => "increment"})
  assert Mob.Screen.get_socket(pid).assigns.count == 1
end
```

## Related packages

| Package | Purpose |
|---------|---------|
| [`mob_dev`](https://hex.pm/packages/mob_dev) | Dev tooling: `mix mob.new`, `mix mob.deploy`, `mix mob.connect`, live dashboard |
| [`mob_push`](https://hex.pm/packages/mob_push) | Server-side push notifications (APNs + FCM) |

## Documentation

Full documentation at [hexdocs.pm/mob](https://hexdocs.pm/mob), including:

- [Getting Started](https://hexdocs.pm/mob/getting_started.html)
- [Architecture & Prior Art](https://hexdocs.pm/mob/architecture.html) — comparison to LiveView Native, Elixir Desktop, React Native, Flutter, and native development
- [Screen Lifecycle](https://hexdocs.pm/mob/screen_lifecycle.html)
- [Components](https://hexdocs.pm/mob/components.html)
- [Theming](https://hexdocs.pm/mob/theming.html)
- [Navigation](https://hexdocs.pm/mob/navigation.html)
- [Device Capabilities](https://hexdocs.pm/mob/device_capabilities.html)
- [DNS on iOS](https://hexdocs.pm/mob/dns_on_ios.html) — required reading if your app makes HTTPS calls; one-line fix for a non-obvious iOS-only failure mode
- [Testing](https://hexdocs.pm/mob/testing.html)

## License

MIT
