# Coming from Phoenix LiveView

A Mob screen is shaped like a LiveView: a process holding a socket of assigns,
`mount/3`, `render/1`, and callbacks that return `{:noreply, socket}`. The
differences come from where it runs. The screen and its native SwiftUI or
Compose view are on the same phone, so there is no server, no browser, no
WebSocket and no HTML.

This page maps LiveView concepts to Mob. To run an actual Phoenix LiveView
inside the app, see [LiveView Mode](liveview.md).

## The map

| LiveView | Mob | Notes |
|---|---|---|
| `use Phoenix.LiveView` | `use Mob.Screen` | Each screen is its own process. See [Screen Lifecycle](screen_lifecycle.md). |
| `mount/3` | `mount/3` | Runs once, inside the screen process, before the first frame. There is no disconnected/connected double mount and no `connected?/1`. |
| `render/1` with `~H` | `render/1` with `~MOB` | `@assigns`, `:if` and `:for` work as in HEEx. A screen without `render/1` uses a `.mob.heex` template with its source file's name (`home_screen.ex` → `home_screen.mob.heex`). See [Components](components.md). |
| `assign/2,3`, `update/3`, `assign_new/3` | `Mob.Socket.assign/2,3`, `update/3`, `assign_new/3` | Same semantics, except `assign_new/3` takes only a 0-arity function (no `fn assigns -> ... end`). Not imported by `use Mob.Screen`; call them on `Mob.Socket`. |
| `phx-click` + `handle_event/3` | `on_tap={{self(), :tag}}` + `handle_info({:tap, :tag}, socket)` | Native input arrives in `handle_info/2`. `handle_event/3` is for `Mob.Screen.dispatch/3`, mostly in tests. See [Events](events.md). |
| `phx-change` | `on_change={{self(), :tag}}` → `{:change, :tag, value}` | Per field, not per form. |
| `handle_info/2` | `handle_info/2` | Same. Device results (camera, permissions, files) and PubSub messages arrive here too. |
| `assign_async/3` | `assign(:x, :loading)` + `Mob.Socket.start_async/3` + `handle_async/3` | Render a spinner or skeleton while `:loading`. There is no `AsyncResult`. See [async loading](screen_lifecycle.md#handle_async-3). |
| `start_async/3`, `handle_async/3`, `cancel_async/3` | `Mob.Socket.start_async/3`, `handle_async/3`, `Mob.Socket.cancel_async/3` | Same names and result shapes (`{:ok, result}` / `{:exit, reason}`). Starting a name that's still running replaces the older task. |
| `stream/3`, `stream_insert/3` | A list in assigns, rendered with `<LazyList>` | LiveView streams keep rows off the server and diffs off the wire; Mob has neither cost. `<LazyList>` builds only the visible rows. Paginate with `on_end_reached`, which delivers `{:tap, tag}`. See [`:lazy_list`](components.md#lazy_list) and [Infinite scroll](events.md#infinite-scroll). |
| Function components | Function composites and tag composites | Plain functions returning a `~MOB` tree. See [Defining your own components](components.md#defining-your-own-components). |
| `live_component` | Usually a composite plus state in the screen | `Mob.Component` is a different thing: a process paired with a native view. |
| `push_navigate`, `push_patch` | `Mob.Socket.push_screen/3`, `pop_screen/1`, `pop_to/2`, `reset_to/4`, `switch_tab/2` | A stack of screens, not URLs. See [Navigation](navigation.md). |
| `Phoenix.LiveViewTest`: `live/2`, `render_click/2`, `render_async/2` | `Mob.ScreenCase`: `mount_screen/4`, `render_info/2`, `render_event/3`, `render_async/2` | Runs in the test process, no device. Assertions query the view tree, not HTML. See [Testing](testing.md). |
| JS commands, hooks | None | Gestures are native props (see [Events](events.md)). There is no general animation API beyond navigation transitions. |

## Loading data with a skeleton

The usual `assign_async` use, a screen that shows placeholders until its data
arrives:

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
```

The render side, the testing side (`render_async/2`) and the rules (one task
per name, tasks stop with the screen) are in
[Screen Lifecycle → `handle_async/3`](screen_lifecycle.md#handle_async-3).
