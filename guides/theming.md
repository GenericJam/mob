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

**Font tokens** — named fonts declared in the theme's `fonts:` map and passed
via the `font:` prop. `fonts[:default]` applies app-wide to any node that
doesn't set its own `font:`, and `font_fallback:` is an ordered list of names
tried when the resolved font can't be loaded on-device:

```elixir
use Mob.App,
  theme: [
    fonts: %{
      default: Mob.Theme.font("Inter-Regular", from_file: "priv/fonts/Inter-Regular.ttf"),
      heading: Mob.Theme.font("Inter-Bold", from_file: "priv/fonts/Inter-Bold.ttf")
    }
  ]

# Then in any screen:
%{type: :text, props: %{text: "Section", font: :heading}, children: []}
```

See [Styling → Custom fonts](styling.md#custom-fonts) for the full story
(file placement, `Mob.Theme.font/2`, plugin default fonts, fallback rules).

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

Core ships three themes:

- **`Mob.Theme.Light`** / **`Mob.Theme.Dark`** — neutral light and dark baselines
- **`Mob.Theme.Adaptive`** — follows the system light/dark setting

The preset themes moved to the [`mob_themes`](https://hex.pm/packages/mob_themes)
style package in 0.7.0 (see [Style packages](#style-packages) below for activation):

- **`MobThemes.Obsidian`** — dark, neutral with blue accents
- **`MobThemes.ObsidianGlass`** — Obsidian variant with translucent surfaces
- **`MobThemes.Citrus`** — warm background with lime-green primary
- **`MobThemes.Birch`** — warm neutral tones, brown accents
- **`MobThemes.Material3`** — Material 3 baseline palette

There are two ways to set a theme:

**At startup** — pass it to `use Mob.App`. This sets the theme before any screen mounts:

```elixir
defmodule MyApp do
  use Mob.App, theme: Mob.Theme.Dark
  ...
end
```

**At runtime** — call `Mob.Theme.set/1` from `mount/3` or any event handler. Use this when you want the user to be able to switch themes:

```elixir
def mount(_params, _session, socket) do
  Mob.Theme.set(MobThemes.Obsidian)
  {:ok, Mob.Socket.assign(socket, :theme, :obsidian)}
end

def handle_info({:tap, :theme_citrus}, socket) do
  Mob.Theme.set(MobThemes.Citrus)
  {:noreply, Mob.Socket.assign(socket, :theme, :citrus)}
end
```

`Mob.Theme.set/1` is global — it applies to all screens on the next render. If your app only ever uses one theme, the `use Mob.App` option is sufficient and you don't need to call `Mob.Theme.set/1`.

## Overriding individual tokens

Pass a `{module, overrides}` tuple to customise a named theme:

```elixir
use Mob.App, theme: {Mob.Theme.Dark, primary: :rose_500, radius_md: 14}
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
Mob.Theme.set(MobThemes.Citrus)

# Override individual tokens on a named theme
Mob.Theme.set({Mob.Theme.Dark, primary: :violet_500})

# Override against the neutral base
Mob.Theme.set(primary: :pink_500, type_scale: 1.2)

# Use a pre-built struct
Mob.Theme.set(%Mob.Theme{primary: :teal_500, space_scale: 1.1})
```

This is useful for accessibility features (larger type, high-contrast), user-selected themes, or A/B testing.

## Style packages

Theme presets are distributed as **style packages** — a separate lane from
capability plugins. The currently-shipped tier is tokens-only: a style
package contributes theme modules (token sets), nothing native. Activation
in `mob.exs` uses `:styles` rather than `:plugins`:

```elixir
# mix.exs
{:mob_themes, "~> 0.1"}

# mob.exs
config :mob, :styles, [:mob_themes]
config :mob, :default_style, :mob_themes   # boots into MobThemes.Obsidian
```

At boot, core applies the default style's theme (`:mob_themes` defaults to
`MobThemes.Obsidian`). The package's other themes are ordinary theme
modules — switch with `Mob.Theme.set(MobThemes.Citrus)` as usual.

`:default_style` is a *default*, not a mandate: an explicit `Mob.Theme.set/1`
from app code (e.g. restoring a persisted user choice in `on_start/0` or
`mount/3`) outranks it.

See [`MOB_STYLES.md`](MOB_STYLES.md)
for the style-package manifest schema and the design of the richer
(native-override) style tiers.

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

### Raw colors are `0xAARRGGBB` integers, not CSS hex strings

Any color prop also accepts a raw color **as a 32-bit integer literal** in
`0xAARRGGBB` order — **alpha first**, then red, green, blue:

```elixir
%{type: :text, props: %{text: "Hi", text_color: 0xFFFF5733}, children: []}
#                                                ^^                        alpha = FF (fully opaque)
#                                                  FF5733                 red/green/blue
```

This is **not** web/CSS color syntax. Two differences trip people (and coding
assistants) up:

- **It's an integer literal (`0xFFFF5733`), not a string.** A CSS-style
  `"#FF5733"` string is **not** a valid color prop — pass the `0x…` integer.
- **Alpha comes first (`0xAARRGGBB`), not last.** CSS's 8-digit form is
  `#RRGGBBAA` (alpha last); Mob is `0xAARRGGBB` (alpha first), matching the
  Android/`Color`-int and iOS ARGB convention the native layer uses. Putting the
  opacity byte in the wrong place gives a wrong color, not just wrong
  transparency.

**Always include the alpha byte.** `0xFF2196F3` is opaque blue; `0x002196F3`
is fully transparent (alpha `00`). A 6-digit `0x2196F3` is read as
`0x002196F3` — invisible — because the missing top byte defaults to `00`.
The built-in palette entries are all `0xFF…` for this reason, and
`:transparent` is `0x00000000`.

The alpha byte is what makes translucency composable. For example, a frosted
overlay panel is just a box with a semi-transparent background stacked over
content — no special "glass" primitive required:

```elixir
# ~40% black scrim / frosted panel over whatever is behind it
%{type: :box, props: %{background: 0x66000000}, children: [...]}
```

Use raw integers sparingly. Semantic tokens give you free dark-mode and theme switching.

## Pre-styled components on top of tokens

[Mishka Chelekom](packages.md#component-kits) has 70+ components on the web,
with a growing set already ported to Mob (sliders, dialogs, avatars, menus,
and more), all reading these same tokens, so a `Mob.Theme.set/1` call
re-skins them along with the rest of your app — no per-component restyling.
