# Theming

Mob's design token system lets you control color, spacing, and typography across the entire app from one place. Tokens are resolved at render time — change the theme and every component updates automatically on the next render.

## Token types

**Semantic color tokens** describe purpose rather than appearance:

| Token | Role | Default |
|-------|------|---------|
| `:primary` | Main action color | `:blue_500` |
| `:on_primary` | Text/icons on primary | `:white` |
| `:secondary` | Secondary action color | `:gray_600` |
| `:on_secondary` | Text/icons on secondary | `:white` |
| `:background` | Screen background | `:gray_900` |
| `:on_background` | Text on background | `:gray_100` |
| `:surface` | Card / sheet background | `:gray_800` |
| `:surface_raised` | Elevated card background | `:gray_700` |
| `:on_surface` | Text/icons on surface | `:gray_100` |
| `:muted` | Secondary / placeholder text | `:gray_500` |
| `:error` | Error state color | `:red_500` |
| `:on_error` | Text/icons on error | `:white` |
| `:border` | Dividers and outlines | `:gray_700` |

**Spacing tokens** (multiplied by `space_scale`):

| Token | Base value |
|-------|-----------|
| `:space_xs` | 4 |
| `:space_sm` | 8 |
| `:space_md` | 16 |
| `:space_lg` | 24 |
| `:space_xl` | 32 |

**Text size tokens** (multiplied by `type_scale`):

| Token | Base sp |
|-------|---------|
| `:xs` | 12 |
| `:sm` | 14 |
| `:base` | 16 |
| `:lg` | 18 |
| `:xl` | 20 |
| `:"2xl"` | 24 |
| `:"3xl"` | 30 |
| `:"4xl"` | 36 |
| `:"5xl"` | 48 |
| `:"6xl"` | 60 |

**Radius tokens**:

| Token | Default |
|-------|---------|
| `:radius_sm` | 6 |
| `:radius_md` | 10 |
| `:radius_lg` | 16 |
| `:radius_pill` | 100 |

## Using tokens in components

Pass token atoms as prop values for color, spacing, radius, and text size props. The renderer resolves them at render time:

```elixir
%{
  type: :box,
  props: %{
    background:    :surface,          # → active theme's surface color
    padding:       :space_md,         # → 16 × space_scale
    corner_radius: :radius_md,        # → theme's radius_md value
  },
  children: [
    %{type: :text, props: %{
      text:       "Title",
      text_size:  :xl,               # → 20.0 × type_scale
      text_color: :on_surface,       # → active theme's on_surface color
    }, children: []}
  ]
}
```

## Named themes

Mob ships three built-in themes:

- **`Mob.Theme.Obsidian`** — dark, neutral with blue accents (default dark theme)
- **`Mob.Theme.Citrus`** — warm background with lime-green primary
- **`Mob.Theme.Birch`** — warm neutral tones, brown accents

There are two ways to set a theme:

**At startup** — pass it to `use Mob.App`. This sets the theme before any screen mounts:

```elixir
defmodule MyApp do
  use Mob.App, theme: Mob.Theme.Obsidian
  ...
end
```

**At runtime** — call `Mob.Theme.set/1` from `mount/3` or any event handler. Use this when you want the user to be able to switch themes:

```elixir
def mount(_params, _session, socket) do
  Mob.Theme.set(Mob.Theme.Obsidian)
  {:ok, Mob.Socket.assign(socket, :theme, :obsidian)}
end

def handle_info({:tap, :theme_citrus}, socket) do
  Mob.Theme.set(Mob.Theme.Citrus)
  {:noreply, Mob.Socket.assign(socket, :theme, :citrus)}
end
```

`Mob.Theme.set/1` is global — it applies to all screens on the next render. If your app only ever uses one theme, the `use Mob.App` option is sufficient and you don't need to call `Mob.Theme.set/1`.

## Overriding individual tokens

Pass a `{module, overrides}` tuple to customise a named theme:

```elixir
use Mob.App, theme: {Mob.Theme.Obsidian, primary: :rose_500, radius_md: 14}
```

## Building a theme from scratch

Pass a keyword list of overrides against the neutral base:

```elixir
use Mob.App, theme: [primary: :emerald_500, background: :gray_950, type_scale: 1.1]
```

Any tokens not listed inherit from the default neutral base.

## Switching themes at runtime

Call `Mob.Theme.set/1` at any point. The next render will use the new theme:

```elixir
# Switch to a named theme
Mob.Theme.set(Mob.Theme.Citrus)

# Override individual tokens on the current theme
Mob.Theme.set({Mob.Theme.Obsidian, primary: :violet_500})

# Override against the neutral base
Mob.Theme.set(primary: :pink_500, type_scale: 1.2)

# Use a pre-built struct
Mob.Theme.set(%Mob.Theme{primary: :teal_500, space_scale: 1.1})
```

This is useful for accessibility features (larger type, high-contrast), user-selected themes, or A/B testing.

## Publishing a custom theme

A theme is any module that exports `theme/0 :: Mob.Theme.t()`:

```elixir
defmodule AcmeCorp.BrandTheme do
  def theme do
    %Mob.Theme{
      primary:    :blue_700,
      on_primary: :white,
      surface:    0xFFF5F0E8,   # exact ARGB hex also accepted
      ...
    }
  end
end
```

Publish it as a Hex package. Anyone can use it:

```elixir
use Mob.App, theme: AcmeCorp.BrandTheme
```

## Base palette

Token atoms that are not semantic theme tokens resolve through the built-in palette. The palette covers grays, blues, greens, reds, oranges, purples, teals, pinks, and more — all as `name_weight` atoms (e.g. `:blue_500`, `:gray_200`, `:emerald_400`).

You can also pass raw ARGB hex integers directly as prop values:

```elixir
%{type: :text, props: %{text: "Hi", text_color: 0xFFFF5733}, children: []}
```

Use raw integers sparingly. Semantic tokens give you free dark-mode and theme switching.
