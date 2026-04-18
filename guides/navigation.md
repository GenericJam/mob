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

A bottom tab bar (iOS: `UITabBarController`, Android: `NavigationBar`) containing multiple named stacks:

```elixir
tab_bar([
  stack(:home,    root: MyApp.HomeScreen,    title: "Home"),
  stack(:search,  root: MyApp.SearchScreen,  title: "Search"),
  stack(:profile, root: MyApp.ProfileScreen, title: "Profile")
])
```

### Drawer

A side drawer (Android: `ModalNavigationDrawer`, iOS: custom slide-in panel) containing multiple named stacks:

```elixir
drawer([
  stack(:home,     root: MyApp.HomeScreen,     title: "Home"),
  stack(:settings, root: MyApp.SettingsScreen, title: "Settings")
])
```

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
def handle_event("tap", %{"tag" => "open_detail"}, socket) do
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
def handle_event("tap", %{"tag" => "back"}, socket) do
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

### `reset_to/2,3`

Replace the entire navigation stack with a new root. No back button, no history. Used for auth transitions:

```elixir
# After login — go to home with no way to navigate back to the login screen
def handle_event("tap", %{"tag" => "logged_in"}, socket) do
  {:noreply, Mob.Socket.reset_to(socket, MyApp.HomeScreen)}
end
```

### `switch_tab/2`

Switch to a named tab in a tab bar or drawer layout:

```elixir
Mob.Socket.switch_tab(socket, :settings)
```

## Navigation animations

The framework automatically picks the right animation based on the navigation action:
- **Push** — slide in from right (iOS) / slide up (Android)
- **Pop** — reverse slide
- **Reset** — cross-fade (no directional animation, no back history)

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
