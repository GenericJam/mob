# Screen Lifecycle

A Mob screen is a GenServer wrapped by `Mob.Screen`. Each screen in the navigation stack is a separate, supervised process. Understanding the lifecycle means understanding when each callback fires and what you can do in it.

## Callbacks

### `mount/3`

```elixir
@callback mount(params :: map(), session :: map(), socket :: Mob.Socket.t()) ::
  {:ok, Mob.Socket.t()} | {:error, term()}
```

Called once when the screen process starts. Initialize your assigns here.

`params` comes from the navigation call that opened this screen:

```elixir
# Screen A navigates to Screen B with params:
Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{id: 42})

# Screen B receives them in mount:
def mount(%{id: id}, _session, socket) do
  item = fetch_item(id)
  {:ok, Mob.Socket.assign(socket, :item, item)}
end
```

`session` is reserved for future use; pass it through.

If `mount/3` returns `{:error, reason}`, the GenServer stops with that reason.

### `render/1`

```elixir
@callback render(assigns :: map()) :: map()
```

Returns the component tree as a plain Elixir map. Called after every callback that returns a modified socket. The renderer serialises the tree, resolves tokens, and calls the NIF — Compose or SwiftUI diffs and updates the display.

The `~MOB` sigil (imported automatically by `use Mob.Screen`) compiles to the same maps at compile time:

```elixir
def render(assigns) do
  ~MOB"""
  <Column padding={:space_md} background={:background}>
    <Text text={assigns.title} text_size={:xl} text_color={:on_background} />
    <Button text="Save" on_tap={{self(), :save}} />
  </Column>
  """
end
```

Keep `render/1` pure. No side effects, no process sends. It may be called more than once for a given state.

### `handle_info/2`

```elixir
@callback handle_info(message :: term(), socket :: Mob.Socket.t()) ::
  {:noreply, Mob.Socket.t()}
```

The primary callback for responding to user interaction and async results. All UI events — taps, text changes, list selections — arrive here as messages sent by the NIF directly to the screen process.

**Tap events** are delivered as `{:tap, tag}` where `tag` is the second element of the `on_tap: {pid, tag}` tuple you specified in `render/1`:

```elixir
# In render:
~MOB(<Button text="Save" on_tap={tap} />) # where tap = {self(), :save}

# In handle_info:
def handle_info({:tap, :save}, socket) do
  save_data(socket.assigns)
  {:noreply, socket}
end
```

**Text field changes** arrive as `{:change, tag, value}`:

```elixir
# In render — pre-compute the handler tuple:
name_change = {self(), :name_changed}
~MOB(<TextField value={assigns.name} on_change={name_change} />)

# In handle_info:
def handle_info({:change, :name_changed, value}, socket) do
  {:noreply, Mob.Socket.assign(socket, :name, value)}
end
```

**Device API results** also arrive here — see [Device Capabilities](device_capabilities.md):

```elixir
def handle_info({:camera, :photo, %{path: path}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :photo_path, path)}
end

def handle_info({:camera, :cancelled}, socket) do
  {:noreply, socket}
end
```

Navigation is triggered by returning a modified socket:

```elixir
def handle_info({:tap, :open_detail}, socket) do
  {:noreply, Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{id: socket.assigns.id})}
end
```

The default implementation (from `use Mob.Screen`) is a no-op that returns the socket unchanged. Always add a catch-all clause to handle messages you don't care about:

```elixir
def handle_info(_message, socket), do: {:noreply, socket}
```

### `handle_event/3`

```elixir
@callback handle_event(event :: String.t(), params :: map(), socket :: Mob.Socket.t()) ::
  {:noreply, Mob.Socket.t()} | {:reply, map(), socket :: Mob.Socket.t()}
```

Dispatched programmatically via `Mob.Screen.dispatch/3` — used in tests to send string-keyed events to a screen process. Not called for normal UI interactions (those go through `handle_info/2`).

```elixir
# In tests:
Mob.Screen.dispatch(pid, "increment", %{})
Mob.Screen.dispatch(pid, "tap", %{"tag" => "save"})

# In the screen:
def handle_event("increment", _params, socket) do
  {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
end
```

The default implementation (from `use Mob.Screen`) raises for any unhandled event, so only define clauses for events you explicitly dispatch.

### `terminate/2`

```elixir
@callback terminate(reason :: term(), socket :: Mob.Socket.t()) :: term()
```

Called when the screen process is about to stop. Use it for cleanup — cancel timers, release resources. The return value is ignored.

The default is a no-op. Most screens don't need to implement this.

## Lifecycle flow

```
start_root/2 or push_screen/2
        │
        ▼
   mount/3  ──────────────────────────────────────────────┐
        │                                                  │
        ▼                                                  │
   render/1  ─ NIF set_root / set_view                    │
        │                                                  │
        ├── user taps button ────► handle_info/2  ──► render/1
        │                                                  │
        ├── text field change ───► handle_info/2  ──► render/1
        │                                                  │
        ├── device API result ───► handle_info/2  ──► render/1
        │                                                  │
        ├── send(pid, msg)  ──────► handle_info/2  ──► render/1
        │                                                  │
        └── screen popped from stack ─► terminate/2  ──────┘
```

## The socket

All callbacks receive and return a `Mob.Socket.t()`. Think of it as a struct carrying your screen's state:

- `socket.assigns` — your data (`:count`, `:user`, `:items`, etc.)
- `socket.__mob__` — internal framework state; do not touch directly

Use `Mob.Socket.assign/2,3` to update assigns. Use the navigation functions (`push_screen`, `pop_screen`, etc.) to queue navigation actions. Both return a new socket; they never mutate in place.

```elixir
socket
|> Mob.Socket.assign(:loading, false)
|> Mob.Socket.assign(:items, items)
|> Mob.Socket.push_screen(MyApp.DetailScreen, %{id: id})
```

## Safe area

The socket always has a `:safe_area` assign populated by the framework:

```elixir
assigns.safe_area
#=> %{top: 62.0, right: 0.0, bottom: 34.0, left: 0.0}
```

Use it to avoid content being obscured by the notch, home indicator, or status bar:

```elixir
def render(assigns) do
  sa = assigns.safe_area
  top    = {self(), :top}
  bottom = {self(), :bottom}
  ~MOB"""
  <Column padding_top={sa.top} padding_bottom={sa.bottom}>
    ...
  </Column>
  """
end
```

## System back

The framework handles the system back gesture (Android hardware back / swipe, iOS edge-pan) automatically. If there is a screen behind the current one in the navigation stack, it pops. If the stack is empty, the app exits. You do not need to handle `{:mob, :back}` unless you want to override this behaviour.
