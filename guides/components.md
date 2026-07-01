# Components

The `~MOB` sigil (imported automatically by `use Mob.Screen`) is the primary way to write Mob UI. It compiles to plain Elixir maps at compile time — there is no runtime overhead.

## Sigil syntax

```elixir
~MOB"""
<Column padding={16}>
  <Text text="Hello" text_size={:xl} />
  <Button text="Save" on_tap={tap} />
</Column>
"""
```

Expression attributes use `{...}` and support any Elixir expression. For `on_tap` and similar handler props, pre-compute the `{pid, tag}` tuple before the sigil to avoid nested parentheses:

```elixir
def render(assigns) do
  save_tap = {self(), :save}
  ~MOB"""
  <Column padding={16}>
    <Text text={"Count: #{assigns.count}"} text_size={:xl} />
    <Button text="Save" on_tap={save_tap} />
  </Column>
  """
end
```

Expression child slots use `{...}` and accept a single node map or a list:

```elixir
~MOB"""
<Column>
  {Enum.map(assigns.items, fn item ->
    ~MOB(<Text text={item} />)
  end)}
</Column>
"""
```

## Control flow

The sigil borrows three authoring idioms from Phoenix HEEx, so screens read the way LiveView developers expect.

### `@assigns` shorthand

Inside any `{...}` expression, `@foo` rewrites to `assigns.foo` (this happens at compile time). It works in attribute values, `{expr}` children, and the `:if`/`:for` directives below. Nested access like `@user.name` works too.

```elixir
def render(assigns) do
  ~MOB"""
  <Column padding={16}>
    <Text text={@title} text_size={:xl} />
    <Text text={"by #{@author.name}"} />
  </Column>
  """
end
```

`@title` is exactly `assigns.title` — the two forms are interchangeable, so reach for whichever reads better.

### `:if` — conditional rendering

`:if={expr}` renders the element only when the expression is truthy. A falsy `:if` drops the element entirely (it does not render an empty placeholder):

```elixir
~MOB"""
<Column>
  <Badge text="New" :if={@unread > 0} />
  <Text text="All caught up" :if={@unread == 0} />
</Column>
"""
```

### `:for` — comprehension

`:for={x <- list}` repeats the element once per item and splices the results into the parent's children:

```elixir
~MOB"""
<Column>
  <Row :for={user <- @users}>
    <Text text={user.name} />
  </Row>
</Column>
"""
```

This is the declarative equivalent of the `{Enum.map(...)}` child slot shown above — use whichever is clearer for the case at hand.

### Combining `:for` and `:if`

When both are present on the same element, `:if` acts as a comprehension filter (matching LiveView): an element is produced only for items where the condition holds.

```elixir
# Renders a Text for 2 and 4 only
<Text text={to_string(n)} :for={n <- 1..4} :if={rem(n, 2) == 0} />
```

`:if` and `:for` each require a `{expr}` value — `:if="true"` (a string) raises a `CompileError`. Only `:if` and `:for` are recognised; any other `:`-prefixed attribute is a compile-time error.

## Map syntax

The sigil compiles to plain maps. You can also write them directly — useful when building components programmatically:

```elixir
%{
  type:     :column,
  props:    %{padding: 16},
  children: [
    %{type: :text,   props: %{text: "Hello", text_size: :xl}, children: []},
    %{type: :button, props: %{text: "Save",  on_tap: {self(), :save}}, children: []}
  ]
}
```

The two styles are fully interchangeable — you can mix them freely in the same `render/1` function.

---

`Mob.Renderer` serialises the component tree to JSON and passes it to the native side in a single NIF call. Compose (Android) and SwiftUI (iOS) handle diffing and rendering.

## Prop values

Props accept:

- **Integers and floats** — used as-is (dp on Android, pt on iOS)
- **Strings** — used as-is
- **Booleans** — used as-is
- **Color atoms** (`:primary`, `:blue_500`, etc.) — resolved via the active theme and the base palette to ARGB integers. See [Theming](theming.md).
- **Spacing tokens** (`:space_xs`, `:space_sm`, `:space_md`, `:space_lg`, `:space_xl`) — scaled by `theme.space_scale` and resolved to integers.
- **Radius tokens** (`:radius_sm`, `:radius_md`, `:radius_lg`, `:radius_pill`) — resolved to integers from the active theme.
- **Text size tokens** (`:xs`, `:sm`, `:base`, `:lg`, `:xl`, `:2xl`, `:3xl`, `:4xl`, `:5xl`, `:6xl`) — scaled by `theme.type_scale` and resolved to floats.

## Platform-specific props

Wrap props in `:ios` or `:android` to apply them only on that platform:

```elixir
props: %{
  padding: 12,
  ios: %{padding: 20}   # iOS sees 20; Android sees 12
}
```

## Layout components

### `:column`

Stacks children vertically.

| Prop | Type | Description |
|------|------|-------------|
| `padding` | number / token | Uniform padding |
| `padding_top`, `padding_bottom`, `padding_left`, `padding_right` | number / token | Per-side padding |
| `gap` | number / token | Space between children |
| `background` | color | Background color |
| `fill_width` | boolean | Stretch to fill available width (default `true`) |
| `fill_height` | boolean | Stretch to fill available height |
| `align` | `:start` / `:center` / `:end` | Cross-axis alignment of children |

### `:row`

Lays out children horizontally.

| Prop | Type | Description |
|------|------|-------------|
| `padding` | number / token | Uniform padding |
| `gap` | number / token | Space between children |
| `background` | color | Background color |
| `fill_width` | boolean | Stretch to fill available width |
| `align` | `:start` / `:center` / `:end` | Cross-axis alignment of children |

To distribute children evenly across a row, give each child a `weight` prop (analogous to `flex: 1` in CSS):

```elixir
save_tap   = {self(), :save}
cancel_tap = {self(), :cancel}
~MOB"""
<Row fill_width={true}>
  <Button text="Cancel" on_tap={cancel_tap} weight={1} background={:surface} text_color={:on_surface} />
  <Spacer size={8} />
  <Button text="Save" on_tap={save_tap} weight={1} />
</Row>
"""
```

### `:box`

A single-child container. Use it to add background, padding, or corner radius to a child:

```elixir
box_style = {self(), :box}
~MOB"""
<Box background={:surface} padding={:space_md} corner_radius={:radius_md}>
  <Text text="Card content" />
</Box>
"""
```

| Prop | Type | Description |
|------|------|-------------|
| `padding` | number / token | Uniform padding |
| `background` | color | Background color |
| `corner_radius` | number / token | Corner radius |
| `fill_width` | boolean | Stretch to fill available width |

### `:scroll`

A vertically scrolling container.

| Prop | Type | Description |
|------|------|-------------|
| `padding` | number / token | Padding inside the scroll area |
| `background` | color | Background color |

### `:spacer`

Inserts fixed space in a row or column, or fills available space when no `size` is given.

| Prop | Type | Description |
|------|------|-------------|
| `size` | number | Fixed size in dp/pt. Omit to fill remaining space. |

```elixir
# Fixed gap:
~MOB(<Spacer size={16} />)

# Push children to opposite ends of a row:
~MOB"""
<Row>
  <Text text="Left" />
  <Spacer />
  <Text text="Right" />
</Row>
"""
```

## List components

### `:list`

A platform-native scrolling list optimised for rendering many rows efficiently. Prefer this over `:scroll` + `:column` for any list of more than ~20 items.

| Prop | Type | Description |
|------|------|-------------|
| `items` | list | Data items. Each renders as a child. |
| `on_select` | `{pid, tag}` | Called when a row is tapped: `{:select, tag, index}` |

```elixir
select = {self(), :item_tapped}
~MOB"""
<List items={assigns.names} on_select={select}>
  {Enum.map(assigns.names, fn name ->
    ~MOB(<Text text={name} padding={:space_md} />)
  end)}
</List>
"""
```

### `:lazy_list`

A virtualized list that renders rows on demand. Supports `on_end_reached` for pagination.

| Prop | Type | Description |
|------|------|-------------|
| `on_end_reached` | `{pid, tag}` | Fired when the user scrolls near the end: `{:tap, tag}` |

## Content components

### `:text`

Displays a string.

| Prop | Type | Description |
|------|------|-------------|
| `text` | string | The text to display (required) |
| `text_size` | number / token | Font size |
| `text_color` | color | Text color |
| `font_weight` | `"regular"` / `"medium"` / `"bold"` | Font weight |
| `text_align` | `"left"` / `"center"` / `"right"` | Horizontal alignment |

### `:button`

A tappable button. Has sensible defaults injected by the renderer (primary background, on_primary text, medium radius, fill width).

| Prop | Type | Description |
|------|------|-------------|
| `text` | string | Button label |
| `on_tap` | `{pid, tag}` | Tap handler. Delivers `{:tap, tag}` to `handle_info/2`. |
| `background` | color | Background color (default `:primary`) |
| `text_color` | color | Label color (default `:on_primary`) |
| `text_size` | number / token | Font size (default `:base`) |
| `font_weight` | string | Font weight (default `"medium"`) |
| `padding` | number / token | Padding (default `:space_md`) |
| `corner_radius` | number / token | Corner radius (default `:radius_md`) |
| `fill_width` | boolean | Fill available width (default `true`) |
| `weight` | float | Flex weight inside a `:row` or `:column` |
| `disabled` | boolean | Disable tap interaction |

```elixir
save_tap   = {self(), :save}
cancel_tap = {self(), :cancel}
~MOB(<Button text="Save" on_tap={save_tap} />)
~MOB(<Button text="Cancel" on_tap={cancel_tap} background={:surface} text_color={:on_surface} />)
```

### `:text_field`

An editable text input. Has defaults injected by the renderer (surface_raised background, border, small radius).

| Prop | Type | Description |
|------|------|-------------|
| `value` | string | Current text (controlled) |
| `placeholder` | string | Hint text when empty |
| `on_change` | `{pid, tag}` | Fires as the user types. Delivers `{:change, tag, value}` to `handle_info/2`. |
| `on_submit` | `{pid, tag}` | Fires on keyboard return. Delivers `{:tap, tag}`. |
| `on_focus` | `{pid, tag}` | Fires when the field gains focus. Delivers `{:tap, tag}`. |
| `on_blur` | `{pid, tag}` | Fires when the field loses focus. Delivers `{:tap, tag}`. |
| `secure` | boolean | Password masking |
| `keyboard_type` | `:default` / `:email` / `:number` / `:phone` | Keyboard variant |
| `background` | color | Background (default `:surface_raised`) |
| `text_color` | color | Input text color (default `:on_surface`) |
| `placeholder_color` | color | Placeholder color (default `:muted`) |
| `border_color` | color | Border color (default `:border`) |
| `padding` | number / token | Padding (default `:space_sm`) |
| `corner_radius` | number / token | Corner radius (default `:radius_sm`) |

### `:divider`

A horizontal rule. Default color is `:border`.

| Prop | Type | Description |
|------|------|-------------|
| `color` | color | Line color (default `:border`) |

### `:progress`

An indeterminate activity indicator (spinner).

| Prop | Type | Description |
|------|------|-------------|
| `color` | color | Indicator color (default `:primary`) |

### `:toggle`

A boolean switch. Delivers `{:change, tag, value}` to `handle_info/2` where `value` is `true` or `false`.

| Prop | Type | Description |
|------|------|-------------|
| `value` | boolean | Current checked state |
| `label` | string | Label text displayed beside the toggle |
| `on_change` | `{pid, tag}` | Fires when toggled. Delivers `{:change, tag, bool}`. |
| `color` | color | Thumb/track tint color |

```elixir
toggle_change = {self(), :notifications_toggled}
~MOB(<Toggle value={assigns.notifications_on} label="Enable notifications" on_change={toggle_change} />)

def handle_info({:change, :notifications_toggled, enabled}, socket) do
  {:noreply, Mob.Socket.assign(socket, :notifications_on, enabled)}
end
```

### `:slider`

A continuous value input. Delivers `{:change, tag, value}` to `handle_info/2` where `value` is a float.

| Prop | Type | Description |
|------|------|-------------|
| `value` | float | Current value |
| `min` | float | Minimum value (default `0.0`) |
| `max` | float | Maximum value (default `1.0`) |
| `on_change` | `{pid, tag}` | Fires as the user drags. Delivers `{:change, tag, float}`. |
| `color` | color | Track and thumb color |

```elixir
volume_change = {self(), :volume_changed}
~MOB(<Slider value={assigns.volume} min={0.0} max={1.0} on_change={volume_change} />)

def handle_info({:change, :volume_changed, value}, socket) do
  {:noreply, Mob.Socket.assign(socket, :volume, value)}
end
```

## Native view components

### `:webview`

Embeds a native web view. Communicates bidirectionally with JS via the `window.mob` bridge. See [WebView](device_capabilities.md#webview) for the full message-passing API.

| Prop | Type | Description |
|------|------|-------------|
| `url` | string | Initial URL to load (required) |
| `allow` | list of strings | URL prefixes that are allowed to navigate; others are blocked and delivered as `{:webview, :blocked, url}` |
| `show_url` | boolean | Show the native URL bar |
| `title` | string | Static title label, overrides `show_url` |
| `width` | number | Fixed width in dp/pt |
| `height` | number | Fixed height in dp/pt |
| `weight` | float | Flex weight inside a `:row` or `:column` |

```elixir
~MOB"""
<WebView url="https://example.com"
         allow={["https://example.com"]}
         show_url={true}
         weight={1} />
"""
```

### `:camera_preview`

Displays a live camera feed inline. The `<CameraPreview>` node itself ships in core, but the preview session is driven by `MobCamera` (the `mob_camera` plugin — add the dep + activate in `mob.exs`; see the [Plugins guide](plugins.md)). Call `MobCamera.start_preview/2` before rendering and `MobCamera.stop_preview/1` in `terminate/2`. No OS permission dialog is shown for preview alone.

| Prop | Type | Description |
|------|------|-------------|
| `facing` | `:back` / `:front` | Camera to use |
| `weight` | float | Flex weight inside a `:row` or `:column` |
| `width` | number | Fixed width in dp/pt |
| `height` | number | Fixed height in dp/pt |

```elixir
def mount(_params, _session, socket) do
  socket = MobCamera.start_preview(socket, facing: :back)
  {:ok, socket}
end

def render(assigns) do
  flip_tap = {self(), :flip}
  ~MOB"""
  <Column>
    <CameraPreview facing={:back} weight={1} />
    <Button text="Flip" on_tap={flip_tap} />
  </Column>
  """
end

def terminate(_reason, socket) do
  MobCamera.stop_preview(socket)
  :ok
end
```

## Defining your own components

You can build reusable components out of the built-in widgets with no native
code, in two forms: **function composites** (a plain function you call) and
**tag composites** (a custom `<Tag>` you register). Both are stateless, pure
Elixir, and hot-pushable. Events raised from inside either kind route to the
**screen's** `handle_info/2`, exactly like a built-in widget does.

### Function composites

A function composite is a function that returns a render tree. You call it
through `{...}` interpolation inside the sigil. This is the lightest way to
factor out a chunk of UI you repeat.

Here is a complete screen that defines a `stat_card/3` composite and uses it.
The tap target is built in `render/1` and passed in as an argument, so the
button inside the composite delivers to this screen's `handle_info/2`:

```elixir
defmodule MyApp.DashboardScreen do
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :taps, 0)}
  end

  # A function composite: returns a render tree, so it drops into the screen
  # via {...}. `on_tap` is a pre-built {pid, tag} tuple passed in by the caller.
  defp stat_card(label, value, on_tap) do
    ~MOB"""
    <Box background={:surface_raised} corner_radius={:radius_md} padding={:space_md}>
      <Column gap={4}>
        <Text text={label} text_size={:sm} text_color={:muted} />
        <Text text={to_string(value)} text_size={:2xl} text_color={:on_surface} />
        <Button text="Tap me" on_tap={on_tap} />
      </Column>
    </Box>
    """
  end

  @impl true
  def render(assigns) do
    bump = {self(), :bump}

    ~MOB"""
    <Column padding={:space_lg} gap={12}>
      <Text text="Dashboard" text_size={:xl} text_color={:on_surface} />
      {stat_card("Taps", @taps, bump)}
    </Column>
    """
  end

  @impl true
  def handle_info({:tap, :bump}, socket) do
    {:noreply, Mob.Socket.update(socket, :taps, &(&1 + 1))}
  end
end
```

Two things to notice:

- `@taps` inside `{stat_card(...)}` is `assigns.taps` (the `@` shorthand works
  in any `{...}` expression, including a composite call).
- The composite is a plain function call in `render/1`, which runs in the screen
  process, so events from the `<Button>` inside it reach this screen. Building
  the `{self(), :bump}` tuple in `render/1` and passing it in keeps the
  composite reusable and follows the pre-compute-the-tuple convention.

### Tag composites

A tag composite gives you custom tag syntax, like `<Card title="...">`. You
register an *expander* for the tag, then write the tag in any screen.

The sigil turns a PascalCase tag into a snake_case atom (`<Card>` becomes
`:card`, `<LabeledButton>` becomes `:labeled_button`), and the expander is
looked up by that atom. An expander is a function `expand(props, children, ctx)`
that returns a render tree (`~MOB` output).

**Step 1 — write the expanders.** `Card` wraps its children in a titled
surface; `LabeledButton` raises a tap event:

```elixir
defmodule MyApp.UI.Card do
  @moduledoc "`<Card title=\"...\">children</Card>` — a titled raised surface."
  import Mob.Sigil

  @spec expand(map(), [map()], map()) :: map()
  def expand(props, children, _ctx) do
    title = Map.get(props, :title, "")

    ~MOB"""
    <Column background={:surface_raised} corner_radius={:radius_md} padding={:space_md}>
      <Text text={title} text_size={:lg} text_color={:on_surface} />
      <Spacer size={8} />
      {children}
    </Column>
    """
  end
end

defmodule MyApp.UI.LabeledButton do
  @moduledoc ~S(`<LabeledButton label="..." on_press="save" />` — a button with an auto-injected tap target.)
  import Mob.Sigil

  @spec expand(map(), [map()], map()) :: map()
  def expand(props, _children, _ctx) do
    label = Map.get(props, :label, "")
    # `on_press` arrives already shaped as {screen_pid, :save} (see "Event
    # ergonomics" below), so we pass it straight to the button's on_tap.
    on_press = Map.fetch!(props, :on_press)

    ~MOB"""
    <Button text={label} on_tap={on_press} />
    """
  end
end
```

`~MOB` is auto-imported inside `use Mob.Screen`, but an expander is a plain
module, so it needs `import Mob.Sigil`.

**Step 2 — register the tags.** Through a plugin manifest's `ui_components`:

```elixir
ui_components: [
  %{tag: "Card",          atom: :card,           expand: {MyApp.UI.Card, :expand}},
  %{tag: "LabeledButton", atom: :labeled_button, expand: {MyApp.UI.LabeledButton, :expand}}
]
```

…or at runtime, for a plain Hex UI kit with no manifest (call from the host's
`on_start/0`) via `Mob.Composite.register/2`:

```elixir
Mob.Composite.register(:card, {MyApp.UI.Card, :expand})
Mob.Composite.register(:labeled_button, {MyApp.UI.LabeledButton, :expand})
```

**Step 3 — use them in a screen.** Note there is no `self()` anywhere in this
markup:

```elixir
defmodule MyApp.ProfileScreen do
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :status, "not saved yet")}
  end

  @impl true
  def render(assigns) do
    ~MOB"""
    <Column padding={:space_lg} gap={12}>
      <Card title="Profile">
        <Text text="Tap save to record it." text_color={:muted} />
        <Spacer size={8} />
        <LabeledButton label="Save" on_press="save" />
      </Card>
      <Card title="Status">
        <Text text={@status} text_color={:primary} />
      </Card>
    </Column>
    """
  end

  @impl true
  def handle_info({:tap, :save}, socket) do
    {:noreply, Mob.Socket.assign(socket, :status, "saved")}
  end
end
```

**The expander contract.** `expand(props, children, ctx)` returns a node map or
a list of nodes, which is re-expanded to a fixpoint so composites can build on
other composites. `ctx` carries the screen process as `ctx.screen`.

**Event ergonomics (auto-injected targets).** Any `on_*` prop you write on a
composite tag as a bare string or atom (`on_press="save"`) arrives in the
expander's `props` already shaped as `{screen_pid, :save}`. That is why
`ProfileScreen` never writes `self()`, and why the screen receives
`{:tap, :save}` in `handle_info/2`.

This auto-injection applies only to a composite tag's **own** props. A built-in
widget you place directly (a `<TextField>` or `<Button>` in a screen's own
markup, even one nested inside a composite's children) still needs an explicit
`{self(), tag}` tuple, because its props are not run through an expander. That
is why `DashboardScreen` above builds `bump = {self(), :bump}` for its plain
`<Button>`, while `ProfileScreen` can write `<LabeledButton on_press="save">`
unadorned: `LabeledButton` is a composite tag, so its `on_press` is shaped for
you.

For the full design see `Mob.Composite` and the "Pure-Elixir composite
components" section of [`MOB_PLUGINS.md`](../MOB_PLUGINS.md). The `mob_demo_kit`
plugin in `mob_plugin_demo` (`<DemoCard>` / `<DemoCombobox>`) is a worked,
device-verified example.

## Using `Mob.Style` for reusable styles

Define shared styles as module attributes and attach them via the `:style` prop. Inline props override style values:

```elixir
@card_style %Mob.Style{props: %{background: :surface, padding: :space_md, corner_radius: :radius_md}}
@title_style %Mob.Style{props: %{text_size: :xl, font_weight: "bold", text_color: :on_surface}}

def render(assigns) do
  %{type: :box, props: %{style: @card_style}, children: [
    %{type: :text, props: %{style: @title_style, text: assigns.title}, children: []},
    %{type: :text, props: %{text: assigns.body,  text_color: :muted,  text_size: :sm}, children: []}
  ]}
end
```

## Tap handler conventions

Use tagged tuples for tap handlers so you can pattern-match on the tag in `handle_info/2`. Pre-compute the tuple before the sigil to avoid nesting parentheses inside `{...}`:

```elixir
def render(assigns) do
  save_tap = {self(), :save}
  ~MOB"""
  <Button text="Save" on_tap={save_tap} />
  """
end

def handle_info({:tap, :save}, socket) do
  ...
end
```

## Event routing

**All events are delivered to the screen process via `handle_info/2`.** `self()` inside `render/1` is always the screen's GenServer pid. Every `on_tap`, `on_change`, `on_select`, and similar handler sends its message directly to the screen process — regardless of how deeply the component is nested in the tree.

| Handler prop | Message delivered to `handle_info/2` |
|---|---|
| `on_tap: {pid, tag}` | `{:tap, tag}` |
| `on_change: {pid, tag}` | `{:change, tag, value}` |
| `on_select: {pid, tag}` (list) | `{:select, tag, index}` |
| `on_submit: {pid, tag}` | `{:tap, tag}` |
| `on_focus: {pid, tag}` | `{:tap, tag}` |
| `on_blur: {pid, tag}` | `{:tap, tag}` |

### Sub-component event isolation (planned, not yet implemented)

A future `Mob.Component` wrapper will allow a subtree of the render tree to have its own `handle_info/2`, routing events to that component process instead of the screen. Until then, use the `tag` field to distinguish events from different parts of the same screen:

```elixir
top_save_tap    = {self(), :top_save}
bottom_save_tap = {self(), :bottom_save}
~MOB"""
<Button text="Top Save"    on_tap={top_save_tap} />
<Button text="Bottom Save" on_tap={bottom_save_tap} />
"""
```

---

## Code formatting

`mix format` understands `~MOB` sigils through `Mob.Formatter`, a first-class
formatter plugin. Generated projects include a `.formatter.exs` that enables it
automatically:

```elixir
# .formatter.exs
[
  plugins: [Mob.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Running `mix format` then normalises indentation, wraps long attribute lists, and
aligns expression children — in a single pass alongside all other Elixir code.

See [Tooling & Formatting](tooling.md) for the full guide and `Mob.Formatter` for
the API reference.
