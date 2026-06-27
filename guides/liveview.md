# LiveView Mode

LiveView mode lets you ship a mobile app using only Phoenix LiveView — no native
UI code required. Mob runs a local Phoenix endpoint on the device and wraps it in
a native WebView. LiveView updates travel over the existing WebSocket at loopback
speed (~1–5 ms).

> **Looking for LiveView-style authoring in native screens?** This guide is about
> running an actual Phoenix LiveView in a WebView. If you instead want the *feel*
> of LiveView while writing native `~MOB` screens, the sigil already mirrors
> several HEEx idioms — `@assigns` shorthand and the `:if` / `:for` control
> attributes — and `Mob.Socket` mirrors `assign/2,3`, `update/3`, and
> `assign_new/3`. See [Components → Control flow](components.md#control-flow).

## Setup

Run this from your Mob project root (the directory with `mix.exs`):

```bash
mix mob.enable liveview
```

This does four things:

1. **Generates `lib/<app>/mob_screen.ex`** — a `Mob.Screen` that opens a WebView
   pointing at `http://127.0.0.1:PORT/`
2. **Patches `assets/js/app.js`** — adds the `MobHook` LiveView hook definition and
   registers it with `LiveSocket`
3. **Patches `root.html.heex`** — adds a hidden `<div id="mob-bridge">` that the hook
   mounts on (see [why this is required](#why-the-hidden-div-is-required))
4. **Creates or updates `mob.exs`** — sets `liveview_port` so `Mob.LiveView.local_url/1`
   knows which port Phoenix is listening on

After running, wire up the screen in your app:

```elixir
# In Mob.App.on_start/0
Mob.Screen.start_root(MyApp.MobScreen)
```

Make sure Phoenix is running on the port set in `mob.exs` (default: 4000).

---

## The two-bridge architecture

Understanding this is essential when something is not working.

There are **two separate JavaScript bridges** that can route messages between your
page's JS and Elixir. They are mutually exclusive — whichever one is active owns
`window.mob`.

### Bridge 1 — The native bridge

The native WebView (iOS `WKWebView` / Android `WebView`) injects a `window.mob`
object into every page it loads. It routes directly through the NIF, bypassing
LiveView entirely.

```
JS → window.mob.send(data)
   → native postMessage / JavascriptInterface
   → NIF (mob_deliver_webview_message)
   → handle_info({:webview, :message, data}, socket)  ← in your Mob.Screen
```

```
Elixir → Mob.WebView.post_message(socket, data)
       → NIF (webview_post_message)
       → evaluateJavascript("window.mob._dispatch(...)")
       → all window.mob.onMessage handlers in JS
```

### Bridge 2 — The LiveView bridge

When `MobHook` mounts it **replaces** `window.mob` with a LiveView-backed version.
Messages now travel over the Phoenix WebSocket.

```
JS → window.mob.send(data)
   → LiveView pushEvent("mob_message", data)
   → handle_event("mob_message", data, socket)  ← in your LiveView
```

```
Elixir → push_event(socket, "mob_push", data)
       → LiveView handleEvent("mob_push", handler)
       → all window.mob.onMessage handlers in JS
```

Your JS code does not need to know which bridge is active — the `window.mob` API
is identical in both modes.

---

## Why the hidden div is required

This is the most commonly missed step when setting up LiveView mode manually.

Phoenix LiveView hooks run their `mounted()` callback **only when**:

1. A DOM element with `phx-hook="MobHook"` exists in the rendered page, **and**
2. The LiveView WebSocket has connected.

Registering `MobHook` in `app.js` is necessary but not sufficient. Without a
matching DOM element the hook is dormant — it never fires, `window.mob` is never
replaced with the LiveView version, and all JS messages silently use Bridge 1
(the native NIF bridge) instead of Bridge 2 (LiveView).

The symptom: `window.mob.send()` appears to work but `handle_event/3` in your
LiveView never receives anything. The messages arrive in `handle_info/2` in your
`Mob.Screen` instead.

`mix mob.enable liveview` adds this element immediately after `<body>` in
`root.html.heex`:

```html
<div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>
```

Placing it at the top of `<body>` ensures the hook mounts as early as possible
after LiveView connects, so `window.mob` is overridden before page-specific JS runs.

### Adding it manually

If `mix mob.enable liveview` could not find `root.html.heex`, or you are setting
up manually, add the element anywhere inside `<body>` in whatever layout file
wraps your entire application:

```html
<body>
  <div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>
  <%= @inner_content %>
</body>
```

---

## Android timing note

On iOS, `window.mob` (Bridge 1) is injected via `WKUserScript` at
`.atDocumentStart` — before any page JavaScript runs.

On Android, it is injected via `evaluateJavascript` in `WebViewClient.onPageFinished`
— after the page has fully loaded. There is a brief window between
`DOMContentLoaded` and `onPageFinished` where `window.mob` is `undefined`.

In practice this is harmless: `MobHook` mounts after LiveView connects, which
happens after `onPageFinished`, so Bridge 2 is in place before any user
interaction is possible.

However, if you call `window.mob` during `DOMContentLoaded`, guard it:

```javascript
document.addEventListener("DOMContentLoaded", () => {
  if (window.mob) window.mob.send({ type: "ready" })
})
```

---

## Using the message API

### Receiving JS messages in a LiveView

```elixir
defmodule MyAppWeb.HomeLive do
  use MyAppWeb, :live_view
  use Mob.LiveView  # optional — see below

  def handle_event("mob_message", %{"event" => "button_tapped", "id" => id}, socket) do
    {:noreply, assign(socket, :last_tap, id)}
  end
end
```

`use Mob.LiveView` is optional. It adds a catch-all `handle_event("mob_message", ...)`
clause that returns `{:noreply, socket}`, so unhandled native events do not crash
your LiveView.

**Important:** defining your own `handle_event/3` replaces the catch-all entirely
(Elixir `defoverridable` semantics). If you define `handle_event/3`, add your own
catch-all for events you do not explicitly handle:

```elixir
def handle_event("mob_message", %{"type" => "ping"}, socket) do
  {:noreply, assign(socket, :pinged, true)}
end

# required — without this, unhandled mob_message events raise FunctionClauseError
def handle_event("mob_message", _data, socket), do: {:noreply, socket}
```

### Pushing messages from Elixir to JS

```elixir
push_event(socket, "mob_push", %{type: "theme_changed", value: "dark"})
```

This calls all handlers registered with `window.mob.onMessage(fn)` in your page JS.

### JS side

```javascript
// Send to Elixir
window.mob.send({ event: "button_tapped", id: "submit" })

// Receive from Elixir
window.mob.onMessage(function(data) {
  if (data.type === "theme_changed") applyTheme(data.value)
})
```

---

## Configuring the port

The WebView loads `http://127.0.0.1:PORT/`. Set the port in `mob.exs`:

```elixir
config :mob, liveview_port: 4000
```

`Mob.LiveView.local_url/1` reads this value:

```elixir
Mob.UI.webview(url: Mob.LiveView.local_url("/"))           # http://127.0.0.1:4000/
Mob.UI.webview(url: Mob.LiveView.local_url("/dashboard"))  # http://127.0.0.1:4000/dashboard
```

Use `127.0.0.1` explicitly — not `localhost`. On Android, `localhost` may resolve
to the host machine rather than the device's own loopback interface.

---

## Troubleshooting

### `handle_event("mob_message", ...)` never fires

The MobHook has not mounted. Check in order:

1. **Is the bridge element present?** Open your `root.html.heex` and confirm
   `<div id="mob-bridge" phx-hook="MobHook" ...>` is inside `<body>`.

2. **Is MobHook registered?** Open `assets/js/app.js` and confirm:
   - `const MobHook = { mounted() { ... } }` is defined
   - `hooks: {MobHook}` (or `hooks: {MobHook, ...}`) is in the `LiveSocket` constructor

3. **Verify at runtime.** Open WebView devtools and run:
   ```javascript
   window.mob.send.toString()
   // Should contain "pushEvent", not "postMessage"
   ```
   If it says `postMessage`, MobHook has not mounted and you are on Bridge 1.

### Messages arrive in `handle_info({:webview, :message, ...})` instead of `handle_event`

Same root cause as above — `window.mob` is still the native bridge. Fix the
bridge element.

### `window.mob` is undefined

On Android during `DOMContentLoaded` this is expected — see the timing note above.
If it is undefined after the page has fully loaded, the native WebView shim failed
to inject. Check the Android logcat for WebView errors.

### LiveView works in the browser but not in the WebView

The BEAM and Phoenix must both run **on-device**, not on your development Mac.
The WebView resolves `127.0.0.1` to the device's own loopback. Run
`mix mob.deploy` to push the app to the device, then confirm the node is
running with `mix mob.connect`.

### Port mismatch

If the WebView shows a connection error, check that:
- `config :mob, liveview_port:` in `mob.exs` matches the port in `config/dev.exs`
  (`config :my_app, MyAppWeb.Endpoint, http: [port: 4000]`)
- Both values are the same number
