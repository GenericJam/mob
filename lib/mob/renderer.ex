defmodule Mob.Renderer do
  @moduledoc """
  Serializes a component tree to JSON and passes it to the platform NIF in
  a single call. Compose (Android) and SwiftUI (iOS) handle diffing and
  rendering internally.

  ## Node format

      %{
        type: :column,
        props: %{padding: :space_md, background: :surface},
        children: [
          %{type: :text,   props: %{text: "Hello", text_size: :xl, text_color: :on_surface}, children: []},
          %{type: :button, props: %{text: "Tap", on_tap: self()},    children: []}
        ]
      }

  ## Token resolution

  Atom values for color props, spacing props, radius props, and text sizes are
  resolved at render time through the active `Mob.Theme` and the base palette.

  **Color props** (`:background`, `:text_color`, `:border_color`, `:color`,
  `:placeholder_color`): resolved via theme semantic tokens first, then the
  base palette. E.g. `:primary` → theme's primary → `:blue_500` → `0xFF2196F3`.

  **Spacing props** (`:padding`, `:padding_top`, etc., `:gap`): accept spacing
  tokens (`:space_xs`, `:space_sm`, `:space_md`, `:space_lg`, `:space_xl`)
  that are scaled by `theme.space_scale`.

  **Radius props** (`:corner_radius`): accept `:radius_sm`, `:radius_md`,
  `:radius_lg`, `:radius_pill` from the active theme.

  **Text size props** (`:text_size`, `:font_size`): token atoms (`:xl`, `:lg`,
  etc.) are multiplied by `theme.type_scale`.

  ## Component defaults

  When a component's props omit styling keys, the renderer injects sensible
  defaults from the active theme. Explicit props always win over defaults.

      # Gets primary background, white text, medium radius automatically:
      %{type: :button, props: %{text: "Save", on_tap: {self(), :save}}, children: []}

  ## Style structs

  A `%Mob.Style{}` value under the `:style` key is merged into the node's
  own props before serialisation. Inline props override style values.

  ## Platform blocks

  Props scoped to one platform are silently ignored on the other:

      props: %{padding: 12, ios: %{padding: 20}}
      # iOS sees padding: 20; Android sees padding: 12

  ## Injecting a mock NIF

      Mob.Renderer.render(tree, :android, MockNIF)
  """

  alias Mob.{Style, Theme}

  @default_nif :mob_nif

  # ── Base palette ──────────────────────────────────────────────────────────
  # Raw named colors. Semantic tokens (:primary, :surface, etc.) resolve
  # through the active Mob.Theme first, then fall through to this table.

  @colors %{
    # Semantic fallbacks (used when no theme is configured or as base values)
    primary: 0xFF2196F3,
    surface: 0xFFFFFFFF,
    on_primary: 0xFFFFFFFF,
    on_surface: 0xFF212121,
    error: 0xFFF44336,
    # Basic
    white: 0xFFFFFFFF,
    black: 0xFF000000,
    transparent: 0x00000000,
    # Grays
    gray_50: 0xFFFAFAFA,
    gray_100: 0xFFF5F5F5,
    gray_200: 0xFFEEEEEE,
    gray_300: 0xFFE0E0E0,
    gray_400: 0xFFBDBDBD,
    gray_500: 0xFF9E9E9E,
    gray_600: 0xFF757575,
    gray_700: 0xFF616161,
    gray_800: 0xFF424242,
    gray_900: 0xFF212121,
    gray_950: 0xFF121212,
    # Blues
    blue_100: 0xFFBBDEFB,
    blue_300: 0xFF64B5F6,
    blue_500: 0xFF2196F3,
    blue_700: 0xFF1976D2,
    blue_900: 0xFF0D47A1,
    # Greens
    green_400: 0xFF66BB6A,
    green_500: 0xFF4CAF50,
    green_700: 0xFF388E3C,
    emerald_400: 0xFF34D399,
    emerald_500: 0xFF10B981,
    emerald_700: 0xFF047857,
    # Reds
    red_400: 0xFFEF5350,
    red_500: 0xFFF44336,
    red_700: 0xFFD32F2F,
    # Oranges / Amber
    orange_400: 0xFFFFA726,
    orange_500: 0xFFFF9800,
    amber_400: 0xFFFBBF24,
    amber_500: 0xFFF59E0B,
    amber_700: 0xFFF57C00,
    # Limes / Yellows
    lime_300: 0xFFBEF264,
    lime_400: 0xFFA3E635,
    lime_500: 0xFF84CC16,
    lime_600: 0xFF65A30D,
    yellow_400: 0xFFFACC15,
    yellow_500: 0xFFEAB308,
    # Purples / Indigo / Violet
    purple_500: 0xFF9C27B0,
    purple_700: 0xFF7B1FA2,
    indigo_500: 0xFF3F51B5,
    deep_purple_700: 0xFF512DA8,
    violet_400: 0xFFA78BFA,
    violet_500: 0xFF8B5CF6,
    violet_600: 0xFF7C3AED,
    violet_700: 0xFF6D28D9,
    # Teals / Cyans
    teal_500: 0xFF009688,
    cyan_500: 0xFF00BCD4,
    # Stone / Warm neutrals
    stone_100: 0xFFF5F5F4,
    stone_200: 0xFFE7E5E4,
    stone_400: 0xFFA8A29E,
    stone_500: 0xFF78716C,
    stone_600: 0xFF57534E,
    stone_800: 0xFF292524,
    # Warm browns
    brown_400: 0xFFA0785A,
    brown_600: 0xFF7C4A1E,
    brown_800: 0xFF3E2010,
    # Pinks / Roses
    pink_500: 0xFFE91E63,
    rose_500: 0xFFF43F5E
  }

  @text_sizes %{
    xs: 12.0,
    sm: 14.0,
    base: 16.0,
    lg: 18.0,
    xl: 20.0,
    "2xl": 24.0,
    "3xl": 30.0,
    "4xl": 36.0,
    "5xl": 48.0,
    "6xl": 60.0
  }

  # Props whose atom values are resolved as colors
  @color_props ~w(background text_color border_color color placeholder_color)a
  # Props whose atom values are resolved as spacing or radius tokens
  @spacing_props ~w(padding padding_top padding_right padding_bottom padding_left gap)a
  @radius_props ~w(corner_radius)a
  # Props whose atom values are resolved as text sizes (scaled by type_scale)
  @size_props ~w(text_size font_size)a

  # ── Component defaults ────────────────────────────────────────────────────
  # Injected for missing styling props. Use semantic tokens so they inherit
  # the active theme automatically. Explicit props always win.

  @component_defaults %{
    button: %{
      background: :primary,
      text_color: :on_primary,
      padding: :space_md,
      corner_radius: :radius_md,
      text_size: :base,
      font_weight: "medium",
      fill_width: true,
      text_align: :center
    },
    text_field: %{
      background: :surface_raised,
      text_color: :on_surface,
      placeholder_color: :muted,
      border_color: :border,
      padding: :space_sm,
      corner_radius: :radius_sm,
      text_size: :base
    },
    divider: %{
      color: :border
    },
    progress: %{
      color: :primary
    }
  }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Render a component tree for the given platform.

  Loads the active `Mob.Theme`, clears the tap registry, serialises the tree
  to JSON, and calls `set_root/1` on the NIF. Returns `{:ok, :json_tree}`.

  `transition` is an atom (`:push`, `:pop`, `:reset`, `:none`) for the nav
  animation. Defaults to `:none` (instant swap).
  """
  @spec render(map(), atom(), module() | atom(), atom()) :: {:ok, :json_tree} | {:error, term()}
  def render(tree, platform, nif \\ @default_nif, transition \\ :none) do
    theme = Theme.current()

    ctx = %{
      colors: Theme.color_map(theme),
      spacing: Theme.spacing_map(theme),
      radii: Theme.radius_map(theme),
      type_scale: theme.type_scale
    }

    nif.clear_taps()
    nif.set_transition(transition)

    json =
      tree
      |> prepare(nif, platform, ctx)
      |> :json.encode()
      |> IO.iodata_to_binary()

    nif.set_root(json)
    {:ok, :json_tree}
  end

  @doc "Return the full color palette map (token → ARGB integer)."
  @spec colors() :: %{atom() => non_neg_integer()}
  def colors, do: @colors

  @doc "Return the text-size scale map (token → float sp)."
  @spec text_sizes() :: %{atom() => float()}
  def text_sizes, do: @text_sizes

  # ── Tree preparation ──────────────────────────────────────────────────────

  defp prepare(%{type: type, props: props, children: children}, nif, platform, ctx) do
    defaults = Map.get(@component_defaults, type, %{})
    with_defaults = Map.merge(defaults, props)

    %{
      "type" => Atom.to_string(type),
      "props" => prepare_props(with_defaults, nif, platform, ctx),
      "children" => Enum.map(children, &prepare(&1, nif, platform, ctx))
    }
  end

  defp prepare_props(props, nif, platform, ctx) do
    # 1. Merge any %Mob.Style{} under the :style key (inline props win)
    {style, base} = Map.pop(props, :style)

    merged =
      case style do
        %Style{props: sp} -> Map.merge(sp, base)
        nil -> base
      end

    # 2. Resolve platform blocks (:ios / :android)
    ios_extras = Map.get(merged, :ios, %{})
    android_extras = Map.get(merged, :android, %{})
    platform_extra = if platform == :ios, do: ios_extras, else: android_extras

    final =
      merged
      |> Map.delete(:ios)
      |> Map.delete(:android)
      |> Map.merge(platform_extra)

    # 3. Serialize: convert atom keys, register taps/changes, resolve tokens.
    # on_tap with a tagged tuple also emits "accessibility_id" so test tooling
    # can locate elements by tag name without relying on screen coordinates.
    final
    |> Enum.flat_map(fn
      {:on_tap, pid} when is_pid(pid) ->
        [{"on_tap", nif.register_tap(pid)}]

      {:on_tap, {pid, tag}} when is_pid(pid) and is_atom(tag) ->
        [{"on_tap", nif.register_tap({pid, tag})}, {"accessibility_id", Atom.to_string(tag)}]

      {:on_tap, {pid, tag}} when is_pid(pid) ->
        [{"on_tap", nif.register_tap({pid, tag})}]

      {:on_change, {pid, tag}} when is_pid(pid) ->
        [{"on_change", nif.register_tap({pid, tag})}]

      {:on_focus, {pid, tag}} when is_pid(pid) ->
        [{"on_focus", nif.register_tap({pid, tag})}]

      {:on_blur, {pid, tag}} when is_pid(pid) ->
        [{"on_blur", nif.register_tap({pid, tag})}]

      {:on_submit, {pid, tag}} when is_pid(pid) ->
        [{"on_submit", nif.register_tap({pid, tag})}]

      {:on_end_reached, {pid, tag}} when is_pid(pid) ->
        [{"on_end_reached", nif.register_tap({pid, tag})}]

      {:on_tab_select, {pid, tag}} when is_pid(pid) ->
        [{"on_tab_select", nif.register_tap({pid, tag})}]

      {key, value} ->
        [{Atom.to_string(key), resolve_token(key, value, ctx)}]
    end)
    |> Map.new()
  end

  # ── Token resolution ──────────────────────────────────────────────────────

  # Color props — two-step: theme semantic map → base palette
  defp resolve_token(key, value, ctx) when is_atom(value) and key in @color_props do
    resolve_color(value, ctx.colors)
  end

  # Text size props — scale table value by type_scale
  defp resolve_token(key, value, ctx) when is_atom(value) and key in @size_props do
    case Map.get(@text_sizes, value) do
      nil -> value
      size -> size * ctx.type_scale
    end
  end

  # Spacing props — spacing tokens first, then radius tokens, then pass through
  defp resolve_token(key, value, ctx) when key in @spacing_props do
    cond do
      is_atom(value) ->
        case Map.get(ctx.spacing, value) do
          nil -> value
          v -> v
        end

      true ->
        value
    end
  end

  # Radius props — radius tokens from theme
  defp resolve_token(key, value, ctx) when is_atom(value) and key in @radius_props do
    Map.get(ctx.radii, value, value)
  end

  defp resolve_token(_key, value, _ctx), do: value

  # Two-step color resolution:
  # 1. Check theme semantic map  (:primary → :blue_500)
  # 2. Check base palette        (:blue_500 → 0xFF2196F3)
  # 3. Pass through              (unknown atoms serialise as strings)
  defp resolve_color(value, theme_colors) when is_atom(value) do
    case Map.get(theme_colors, value) do
      nil ->
        Map.get(@colors, value, value)

      palette_atom when is_atom(palette_atom) ->
        Map.get(@colors, palette_atom, palette_atom)

      raw_int when is_integer(raw_int) ->
        raw_int
    end
  end

  defp resolve_color(value, _theme_colors), do: value
end
