# Mob usage rules

Rules for writing a Mob app (Elixir on the phone, native SwiftUI/Compose UI).
Short on purpose. Each rule names its guide: `deps/mob/guides/<name>.md` in an
app (the version in `mix.lock`), or https://hexdocs.pm/mob/<name>.html.

## Where the docs are

- `deps/mob/guides/*.md` and this file: the guides for exactly the mob version
  the app uses (shipped in the package since mob 0.9.17).
- https://hexdocs.pm/mob/llms.txt: index of every guide and module. Each
  page is also available as Markdown: https://hexdocs.pm/mob/screen_lifecycle.md
- `mix hex.docs fetch mob`: offline copy under `~/.hex/docs/hexpm/mob/<version>/`.
- IEx: `h Mob.Socket.start_async`, `h Mob.Screen`.
- Coming from Phoenix LiveView? Start with `deps/mob/guides/coming_from_liveview.md`.

## Screens

- A screen is `use Mob.Screen`: a process holding a socket. Callbacks are
  `mount/3`, `render/1`, `handle_info/2`, `handle_async/3`, `handle_event/3`,
  `terminate/2`. See `deps/mob/guides/screen_lifecycle.md`.
- Update assigns with `Mob.Socket.assign/2,3`, `update/3`, `assign_new/3`.
  They aren't imported by `use Mob.Screen`; call them on `Mob.Socket`.
- Render with the `~MOB` sigil: `@assigns`, `:if={...}` and `:for={...}`
  work as in HEEx. Keep `render/1` pure. See `deps/mob/guides/components.md`.
- Taps, text changes and other native input arrive in `handle_info/2`
  (`on_tap={{self(), :save}}` → `{:tap, :save}`). Define a catch-all
  `handle_info(_msg, socket)` clause. See `deps/mob/guides/events.md`.

## Async loading

- `mount/3` runs before the first frame: never do slow work (HTTP, big
  queries) there. Assign a placeholder and use
  `Mob.Socket.start_async(socket, name, fun)`. The result arrives in
  `handle_async(name, {:ok, result} | {:exit, reason}, socket)`.
- Don't use a bare `Task.async/1` in a screen: its reply, `:DOWN` and
  `:EXIT` all land in `handle_info/2`. `start_async/3` handles them, stops
  the task with the screen, and keeps only the newest task per name.
- See `deps/mob/guides/screen_lifecycle.md` (section `handle_async/3`).

## Lists

- Long or growing lists use `<LazyList>`, which builds only the visible rows.
  There is no LiveView-style `stream`; keep the list in assigns.
- Paginate with `<LazyList on_end_reached={{self(), :load_more}}>`. It
  delivers `{:tap, :load_more}` (not `{:end_reached, _}`) and only works on
  `<LazyList>`. Handlers must be idempotent. See `deps/mob/guides/events.md`
  (Infinite scroll).
- Give rows a stable `:id`.

## Navigation

- `Mob.Socket.push_screen/3`, `pop_screen/1`, `pop_to/2`, `reset_to/4`,
  `switch_tab/2` return a socket; the navigation happens after the callback
  returns. See `deps/mob/guides/navigation.md`.

## Testing

- Unit-test screens with `Mob.ScreenCase`, no device needed: `mount_screen/4`,
  `render_info/2` (a tap), `render_event/3`, `render_async/2` (await
  `start_async` tasks), plus `assigns/1`, `find/3`, `text/1` and
  `assert_renderable/2`. See `deps/mob/guides/testing.md`.
- On a running app, `Mob.Test` reads state and drives it over Erlang
  distribution (`Mob.Test.assigns/1`, `Mob.Test.tap/2`). Prefer it to
  screenshots. See `deps/mob/guides/agentic_coding.md`.
