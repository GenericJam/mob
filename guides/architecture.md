# Architecture & Prior Art

Mob takes an unusual position in the mobile framework landscape. To understand why it makes the choices it does, it helps to know where it sits relative to what came before.

## The core idea

```mermaid
flowchart TD
    A["Your Elixir App<br/>(GenServers, Phoenix, Ecto, whatever you normally use)"]
    B["Mob.Screen<br/>(your UI module) — GenServer"]
    C["Mob.Renderer<br/>serialise + token resolution"]
    D1["Compose (JVM)<br/>Android"]
    D2["SwiftUI (Swift)<br/>iOS"]

    A -->|OTP supervision tree| B
    B -->|"render/1 → component tree"| C
    C -->|"set_root NIF (JSON)"| D1
    C -->|"set_root NIF (JSON)"| D2
```

BEAM and OTP run **on the device** — embedded inside the APK and the iOS app bundle. There is no server. Your screen logic, navigation state, and business logic all execute locally in the same BEAM node that the user has installed.

The rendering layer is thin: `render/1` returns a plain Elixir map (the component tree), `Mob.Renderer` serialises it to JSON and passes it to the native side via a NIF call. Compose or SwiftUI diff and display it. UI events travel back as NIF callbacks that send messages to the screen GenServer. The BEAM owns state; the native UI is a thin view.

## Erlang distribution for development

Because OTP runs on-device, you can connect a running BEAM node on your phone or simulator directly from IEx on your Mac:

```
mix mob.connect
# → tunnels EPMD, sets up dist, drops into IEx
# → Node.list() shows the device node
# → nl(MyApp.SomeScreen) hot-pushes new bytecode
```

This is not a debug protocol or a proprietary inspector — it is standard Erlang distribution. Any OTP tooling (`:rpc.call`, `:sys.get_state`, `:observer`, tracing) works out of the box.

## Prior art

### Native (Swift / Kotlin)

The baseline. Full access to every platform API, optimal performance, best tooling support. The cost is that iOS and Android are separate codebases in different languages. If you know Swift and Kotlin this is fine; if you are an Elixir backend developer with no mobile experience it is a significant investment.

Mob lets you write mobile apps in Elixir without learning Swift or Kotlin. The native layer exists but you never write it — it ships with the framework.

### React Native

Introduced the idea of a shared JS codebase that talks to native components via a bridge. The JS bundle runs in a separate thread; bridge crossings are asynchronous and involve serialisation overhead. Recent versions (the new architecture) replace the bridge with JSI for direct synchronous calls, which helps, but JS remains a thin runtime rather than a first-class part of the platform.

For Elixir developers, React Native requires a full context switch to JavaScript (or TypeScript), the npm ecosystem, and the React model. Mob uses Elixir throughout and gives you OTP's process model, supervision trees, and distribution for free.

### Flutter

Compiles to native ARM code and ships its own rendering engine (Impeller / Skia). No bridge — the Dart code and the canvas are on the same thread. This gives Flutter excellent performance and near-pixel-perfect rendering consistency across platforms.

The trade-off is Dart: a capable language but a separate ecosystem from Elixir. Flutter also renders its own pixels rather than native UI components, so it can diverge from platform conventions.

Mob renders native Compose and SwiftUI components, so the UI looks and behaves like platform-native apps. The rendering model is Elixir maps → JSON → native diff, not a custom canvas.

### Elixir Desktop

[Elixir Desktop](https://github.com/elixir-desktop/desktop) embeds BEAM in a desktop application using wxWidgets for the UI layer, with a WebView component for HTML/CSS rendering. It has shipping apps in production on macOS, Windows, Linux, iOS, and Android.

Mob and Elixir Desktop share the core insight: embed BEAM on the device and use it as the runtime. The difference is the UI layer. Elixir Desktop renders through wxWidgets and a WebView, giving you HTML/CSS at the cost of a web-rendering pipeline. Mob talks directly to Compose and SwiftUI, giving you native UI components with no browser engine.

If you want HTML/CSS and cross-platform desktop support today, Elixir Desktop is mature and battle-tested. If you want native mobile UI with Elixir, Mob is the path.

### LiveView Native

[LiveView Native](https://native.live) extends Phoenix LiveView so the server renders native UI trees that get pushed over WebSocket to a thin client app. The server is Phoenix; the client is a thin Elixir or Swift shell that receives and applies diffs.

This is well-suited to apps that are already Phoenix-centric, have significant server state, or need real-time sync with a backend. The UI always reflects server state and reconnects automatically.

Mob is the opposite: the BEAM runs on the device, not on a server. There is no server requirement. The app works offline, has zero latency for UI interactions, and deploys as a self-contained installable app. If your app needs a server anyway (auth, data sync, push), you can connect to it however you like — HTTP, WebSocket, Erlang distribution — but the UI logic lives on-device.

The right choice between them depends on your app's connectivity requirements and how much state lives on a server versus on the device.

## What Mob optimises for

- **Elixir all the way down.** One language, one mental model. OTP supervision, GenServers, pattern matching, and the pipe operator work the same in your mobile app as in your backend.
- **Native UI.** Components render as Compose and SwiftUI primitives. Animations, accessibility, platform gestures, and dark mode all work because the native layer handles them.
- **No server required.** The app is self-contained. Online features are optional add-ons, not the foundation.
- **Development speed.** `mix mob.connect` + `nl/1` gives you sub-second code push to a running device. The OTP debug toolchain — tracing, observer, remote IEx — is available without any extra infrastructure.
- **OTP reliability.** A crashed screen is a crashed GenServer. OTP can restart it, log it, and keep the rest of the app running. You get fault tolerance on mobile for free.
