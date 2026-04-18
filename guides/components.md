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
