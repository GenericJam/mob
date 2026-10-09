# Screen Lifecycle

A Mob screen is a GenServer — a `Mob.Screen.Server` process holding your module's socket. Each live screen in the navigation stack is a separate process, and `Mob.Router` owns them: it starts them, stops them, and restarts one that crashes. It is not an OTP `Supervisor`, because only the router knows where in the navigation a crashed screen sat; a restarted screen re-mounts and loses its assigns. Understanding the lifecycle means understanding when each callback fires and what you can do in it.

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

`mount/3` runs before the screen's first frame, so anything slow here (a
network call, a large query) delays the whole screen. Assign a placeholder and
load the data with `Mob.Socket.start_async/3` instead; see
[`handle_async/3`](#handle_async-3) below.

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

### `handle_async/3`

```elixir
@callback handle_async(name :: term(), result :: {:ok, term()} | {:exit, term()}, socket :: Mob.Socket.t()) ::
  {:noreply, Mob.Socket.t()}
```

Receives the outcome of a task started with `Mob.Socket.start_async/3`, the
Mob counterpart of LiveView's `start_async/3` and `handle_async/3`. Use it to
show a screen immediately with a loading state (a spinner, or skeleton boxes)
and fill it in when the data arrives:

```elixir
def mount(%{id: id}, _session, socket) do
  {:ok,
   socket
   |> Mob.Socket.assign(:profile, :loading)
   |> Mob.Socket.start_async(:profile, fn -> MyApp.Api.fetch_profile(id) end)}
end

def handle_async(:profile, {:ok, profile}, socket),
  do: {:noreply, Mob.Socket.assign(socket, :profile, profile)}

def handle_async(:profile, {:exit, reason}, socket),
  do: {:noreply, Mob.Socket.assign(socket, :profile, {:failed, reason})}

def render(assigns) do
  ~MOB"""
  <Column padding={:space_md}>
    <Box :for={_ <- 1..3} :if={@profile == :loading} fill_width={true}
         background={:surface_raised} corner_radius={:radius_sm}>
      <Spacer size={18} />
    </Box>
    <Text :if={is_map(@profile)} text={@profile.name} />
    <Text :if={match?({:failed, _}, @profile)} text="Couldn't load the profile" />
  </Column>
  """
end
```

`{:ok, result}` carries what the function returned. `{:exit, reason}` means it
raised, threw or exited, or was cancelled with `Mob.Socket.cancel_async/3`; a
crashing task does not crash the screen. Neither reaches `handle_info/2`.

- **One task per name.** Starting a name whose task is still running kills the
  older task, and only the newest reports. A search that starts a lookup on
  every keystroke never renders a stale result.
- **Tasks stop with the screen.** A task is linked to the screen that started
  it, and it is stopped when that screen crashes or leaves the navigation stack.
  Work that must outlive the screen belongs in a process of its own.
- **No default.** `use Mob.Screen` does not define `handle_async/3`, and
  `start_async/3` raises `ArgumentError` in a screen that doesn't define it.
- **Testing.** Under `Mob.ScreenCase`, `render_async/2` waits for the screen's
  tasks and delivers their results; see the [testing guide](testing.md).

### `terminate/2`

```elixir
@callback terminate(reason :: term(), socket :: Mob.Socket.t()) :: term()
```

Called when the screen process is about to stop — when the screen is popped
from its stack, or when navigation shuts down and takes its linked screens with
it. Use it for cleanup — cancel timers, release resources. The return value is
ignored. Persisted screens (`use Mob.Screen, vsn: N` or `persist: true`) also
dump their state here, so their assigns survive an app exit.

Only the screen leaving the stack is stopped: on a pop, the screens still below
it in the history stay alive, which is what lets pop restore the previous
screen's state without re-mounting it.

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
        ├── start_async/3 task ──► handle_async/3 ──► render/1
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

On iOS the insets are read from the active window. If the BEAM starts before
that window exists — a background launch connects no window scene at launch, and
an iOS 15+ prewarmed launch runs long before the user taps the icon — the assign
holds zeros until the platform can answer, and the window connecting triggers a
re-read and a repaint.

On device the assign is always present, so `assigns.safe_area` is safe to read
directly. Under `Mob.ScreenCase` it is not: `mount_screen/3` builds a socket
without it, so a test that renders a screen reading `assigns.safe_area` should
assign one in `mount/3` or read it with `assigns[:safe_area]`.

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

## Size class

The socket always has a `:size_class` assign too, `{horizontal, vertical}`,
each `:compact` or `:regular`:

```elixir
assigns.size_class
#=> {:compact, :regular}   # an iPhone in portrait
```

Lay out by size class, not by orientation or screen dimensions. An iPad in
Slide Over is a phone-shaped window on a tablet, and a foldable changes class
when it opens. On iOS the value is the window's trait collection; on Android it
is derived from the window's width and height in dp with Material's
breakpoints (`:regular` from 600dp wide / 480dp tall). `Mob.SizeClass` lists
typical values — note that smaller iPhones are `{:compact, :compact}` in
landscape; only the large ones (Plus, Pro Max, XR/11-class, 414pt wide or
more) reach `{:regular, :compact}`.

When the window changes class — rotation, iPad Split View, Slide Over or Stage
Manager resizes, an Android multi-window resize — every live screen, including
ones under the top of a stack, gets the new value in the assign and then:

```elixir
def handle_info({:mob_size_class_changed, {h, _v}}, socket) do
  # assigns.size_class already holds the new value
  {:noreply, Mob.Socket.assign(socket, :columns, if(h == :regular, do: 2, else: 1))}
end
```

The clause is optional: a screen that only reads `assigns.size_class` in
`render/1` is repainted with the new value without one, and a screen whose
`handle_info/2` has no clause for the message is not crashed by it.

Before iOS has a window (a prewarmed or background launch), and on a build
whose native layer predates size classes, the assign holds `{:compact,
:regular}`; the real value arrives as an ordinary change once the window
appears. Real values need a native rebuild (`mix mob.deploy --native`). On
iPad the app only gets a full-size window if its `Info.plist` declares iPad
support (`UIDeviceFamily` `[1, 2]`); without it iOS runs it letterboxed in an
iPhone-sized window that never changes class.

Under `Mob.ScreenCase`, `mount_screen/4` takes `size_class:` and
`change_size_class/2` simulates a change; see the [testing guide](testing.md).

## Crashes and restarts

A crash in a screen callback kills that screen's process only. The router
observes the exit, restarts the screen in the same navigation slot with its
original mount params, and repaints. The restarted screen runs `mount/3` again
and loses its assigns — persisted screens get their dumped state back through
`load_state/2` — and the restart is logged at error, because a form clearing
itself is visible to the user. Restarts are capped (5 in 10 seconds per screen)
so a screen that crashes on every render cannot spin.

The crash is logged without the screen's data, because on a device the log is
logcat or the iOS console, which `adb` and bug reports read in release builds.
The router's line, OTP's crash report and the exit reason (including the
`reason` your `terminate/2` receives) name the exception's module and its
stacktrace by arity — `KeyError` in `MyScreen.handle_event/3` at line 12 — but
never its message (unless mob wrote it) or the call's arguments: a `KeyError`'s
message embeds the map it searched, and a `FunctionClauseError` frame holds the
socket. The crash report shows the assigns' keys, not their values, and of the
last message only its tag and the names your source defines, never a value
(`{:change, :name, :redacted}`, `{:event, "save", :redacted}`).
`Mob.Agent.Receipts` records which event a crash came from. What you put in
`Logger.metadata/1` or a process label (`:proc_lib.set_label/1`) is kept and
logged with the crash, since that is you choosing to log it, so never put
assigns or secrets there.

Because each screen owns its own process, `self()` in a callback is that
screen's pid. A task or timer started by a screen delivers to that screen —
even if it's parked under an inactive tab — and if the screen has been popped
and stopped, the BEAM drops the message rather than delivering it to whatever
screen is now current.

## System back

The framework handles the system back gesture (Android hardware back / swipe, iOS edge-pan) automatically. If there is a screen behind the current one in the active stack, it pops. At the root of a secondary stack in a `tab_bar/1`/`drawer/1` layout, back switches to the first stack (the Android convention — see [Navigation](navigation.md#tabs-and-multi-stack-state)). At the root of the first (or only) stack, the app exits. You do not need to handle `{:mob, :back}` unless you want to override this behaviour.
