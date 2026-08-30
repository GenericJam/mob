# Navigation

Mob supports three navigation patterns: stack, tab bar, and drawer. These are declared in your app module and managed through `Mob.Socket` functions in your screen callbacks.

## Declaring navigation structure

Navigation is declared in your `Mob.App` module's `navigation/1` callback. The function receives the current platform atom (`:ios` or `:android`) and returns a navigation map:

```elixir
defmodule MyApp do
  use Mob.App

  def navigation(_platform) do
    stack(:home, root: MyApp.HomeScreen)
  end
end
```

Use the helper functions `stack/2`, `tab_bar/1`, and `drawer/1` (imported from `Mob.App`):

### Stack

A linear push/pop navigation hierarchy.

```elixir
stack(:home, root: MyApp.HomeScreen)
stack(:settings, root: MyApp.SettingsScreen, title: "Settings")
```

The first argument is the stack's name atom — it becomes a valid navigation destination. The `:root` option is the screen module mounted when the stack is first entered.

### Tab bar

Multiple named stacks, each with its own independent navigation history:

```elixir
tab_bar([
  stack(:home,    root: MyApp.HomeScreen,    title: "Home"),
  stack(:search,  root: MyApp.SearchScreen,  title: "Search"),
  stack(:profile, root: MyApp.ProfileScreen, title: "Profile")
])
```

Each declared stack keeps its own history *and* its own live screens, so
switching away from a tab and back restores exactly where you were — see
[Tabs and multi-stack state](#tabs-and-multi-stack-state) below.

> **No automatic tab chrome yet.** The runtime fully backs `tab_bar/1` —
> per-stack state is kept and `switch_tab/2` works — but declaring it does not
> yet draw a bottom tab bar. Switching is programmatic via
> `Mob.Socket.switch_tab/2` for now; to draw chrome yourself, render the
> `:tab_bar` *widget* in your screens and wire its `on_tab_select` to
> `switch_tab/2` (see [Styling → Tab bar props](styling.md#tab-bar-props-tab_bar)).

### Drawer

The same shape with drawer semantics — multiple named stacks:

```elixir
drawer([
  stack(:home,     root: MyApp.HomeScreen,     title: "Home"),
  stack(:settings, root: MyApp.SettingsScreen, title: "Settings")
])
```

The multi-stack state rules below apply identically. As with `tab_bar/1`, no
drawer chrome is drawn yet; switching is programmatic.

### Platform-specific navigation

Pass different structures per platform:

```elixir
def navigation(:ios),     do: tab_bar([...])
def navigation(:android), do: drawer([...])
def navigation(_),        do: stack(:home, root: MyApp.HomeScreen)
```

## Navigating between screens

Navigation is queued by returning a modified socket from any callback. The framework processes the nav action after the callback returns, mounts the new screen, and triggers a push/pop animation.

### `push_screen/2,3`

Navigate to a new screen, pushing it onto the stack:

```elixir
def handle_info({:tap, :open_detail}, socket) do
  {:noreply, Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{id: socket.assigns.id})}
end
```

The second argument is either a module or a registered stack name atom:

```elixir
# By module:
Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{id: 42})

# By registered name (from navigation/1):
Mob.Socket.push_screen(socket, :detail, %{id: 42})
```

The params map is passed to the destination screen's `mount/3`.

### `pop_screen/1`

Return to the previous screen:

```elixir
def handle_info({:tap, :back}, socket) do
  {:noreply, Mob.Socket.pop_screen(socket)}
end
```

The system back gesture (Android hardware back / iOS edge-pan) calls this automatically. You do not need to handle it manually in most cases.

### `pop_to/2`

Pop back to a specific screen in the history:

```elixir
# Pop back to the Home screen wherever it is in the stack
Mob.Socket.pop_to(socket, MyApp.HomeScreen)
Mob.Socket.pop_to(socket, :home)  # by name
```

No-op if the screen is not in the history.

### `pop_to_root/1`

Pop all screens back to the root of the current stack:

```elixir
Mob.Socket.pop_to_root(socket)
```

### `reset_to/2,3,4`

Replace the entire navigation stack with a new root. No back button, no history. Used for auth transitions:

```elixir
# After login — go to home with no way to navigate back to the login screen
def handle_info({:tap, :logged_in}, socket) do
  {:noreply, Mob.Socket.reset_to(socket, MyApp.HomeScreen)}
end
```

The reset always replaces the stack. Its animation can be overridden when the
same stack operation represents directional movement, such as custom tabs:

```elixir
Mob.Socket.reset_to(socket, MyApp.PortfolioScreen, %{}, transition: :push)
```

### `switch_tab/2,3`

Switch to a named stack in a tab bar or drawer layout:

```elixir
Mob.Socket.switch_tab(socket, :settings)
```

The first switch to a stack mounts its declared `:root`; later switches restore
the stack exactly as you left it. Switching to the stack you are already on, or
to a name no stack declares, is a no-op. By default a tab switch is an
unanimated swap. Apps with ordered tabs can supply a directional transition:

```elixir
Mob.Socket.switch_tab(socket, :portfolio, transition: :push)
Mob.Socket.switch_tab(socket, :home, transition: :pop)
```

The transition changes only the animation; each tab still retains its own
screen and history stack.

When a tab root needs session or launch data, pass it on the first switch:

```elixir
Mob.Socket.switch_tab(socket, :home,
  transition: :push,
  mount_params: %{session: session}
)
```

`mount_params` must be a map. They are used only when the target stack has not
yet mounted. Switching back to an existing stack restores its original screen
and state; later `mount_params` do not replace the params it mounted with.

## Tabs and multi-stack state

With a `tab_bar/1` or `drawer/1` layout, every declared stack owns its own
history and its own live screens (`Mob.Nav` holds this state). The rules:

- **Stacks materialize on first visit.** A declared stack has no screen and has
  never mounted until it is first switched to — matching `UITabBarController`,
  which does not instantiate a tab's view controller until selected. From the
  second visit onward its state is retained for the app's lifetime.
- **Switching away parks the whole stack.** The parked stack's screen processes
  stay alive with their state, but their renders are not committed — an
  inactive tab holds state without painting. Switching back restores the exact
  screen and history, without re-mounting.
- **Histories are independent.** `pop_screen/1`, `pop_to/2`, and
  `pop_to_root/1` operate on the active stack only; nothing can pop across a
  stack boundary.
- **Back at a secondary stack's root returns to the first stack.** The system
  back gesture at the root of any declared stack other than the first switches
  to the first stack instead of exiting the app (the Android convention). Only
  back at the first stack's root exits.
- **A root outside the layout gets a private stack.** If `start_root/1` mounts
  a screen no stack declares (a splash, login, or deep-link target), it is
  parked under a private orphan stack when you first `switch_tab/2` away. Its
  state is preserved, every declared root stays reachable, and the orphan is
  never itself a switch target.

Known gaps, tracked on the epic: `reset_to/2` does not re-derive which stack
its destination belongs to (MOB-115); parked screens miss `terminate/2` and
persisted-state sync (MOB-116); re-selecting the active tab is a no-op rather
than popping that stack to its root (MOB-117).

## Navigation animations

The framework automatically picks the right animation based on the navigation action:
- **Push** — slide in from right (iOS) / slide up (Android)
- **Pop** — reverse slide
- **Reset** — cross-fade (no directional animation, no back history)
- **Tab switch** — none by default; `switch_tab/3` can request push, pop, or reset

`reset_to/4` can override only the animation with `transition: :push` or
`transition: :pop`; it still discards navigation history. Any other transition
value raises `ArgumentError` — including `:none`, which native would treat as
"not navigation" and diff the incoming tree into the outgoing screen's view
identities. A navigation's animation survives coalescing: an ordinary re-render
(a timer tick, a component update) queued behind a push cannot swallow the
push's animation.

`switch_tab/3` accepts the same validated transition values (`:push`, `:pop`,
or `:reset`) and an optional `mount_params` map. Unlike `reset_to/4`, its
legacy `switch_tab/2` form deliberately uses `:none`, preserving the
unanimated tab-swap behavior.

## Passing data on pop

Mob's navigation is process-based. When you pop back to a previous screen, that screen's process is still running with its original state. To pass data back, send a message to the parent's pid.

Pass the parent pid as a param when pushing:

```elixir
# In the parent screen — pass self() so the child can reply:
def handle_info({:tap, :open_detail}, socket) do
  {:noreply, Mob.Socket.push_screen(socket, MyApp.DetailScreen, %{
    id:         socket.assigns.selected_id,
    parent_pid: self()
  })}
end

# In the parent screen's handle_info:
def handle_info({:saved, item}, socket) do
  {:noreply, Mob.Socket.assign(socket, :selected_item, item)}
end
```

```elixir
# In the detail screen's mount — capture the parent pid from params:
def mount(%{id: id, parent_pid: parent_pid}, _session, socket) do
  {:ok, Mob.Socket.assign(socket, item: fetch_item(id), parent_pid: parent_pid)}
end

# Before popping — send the result back:
def handle_info({:tap, :save}, socket) do
  send(socket.assigns.parent_pid, {:saved, socket.assigns.item})
  {:noreply, Mob.Socket.pop_screen(socket)}
end
```

## The `Mob.Nav.Registry`

Named destinations (the atoms you use in `stack/2`) are registered in `Mob.Nav.Registry` when the app starts. This lets you navigate by name instead of module reference, which is useful for decoupled navigation where a screen shouldn't import its destination's module:

```elixir
# Navigation declaration auto-registers :home → MyApp.HomeScreen
stack(:home, root: MyApp.HomeScreen)

# Later, anywhere:
Mob.Socket.push_screen(socket, :home)  # resolves to MyApp.HomeScreen
```

### Route-bound params

`Mob.Nav.Registry.register/3` can bind a params map to a route, letting many
routes share one parameterized screen module (the data-driven pattern — e.g.
a plugin registering `:post_list` as `{MobAsh.ListScreen, %{resource: MyApp.Post}}`):

```elixir
Mob.Nav.Registry.register(:post_list, MobAsh.ListScreen, %{resource: MyApp.Post})
Mob.Nav.Registry.register(:user_list, MobAsh.ListScreen, %{resource: MyApp.User})
```

When such a route is the navigation destination, the route-bound params are
merged *under* the caller's `push_screen` params (the caller's keys win on
conflict) and the merged map is what arrives in the destination's `mount/3`.
