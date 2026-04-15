defmodule Mob.Renderer do
  @moduledoc """
  Serializes a component tree to JSON and passes it to the platform NIF in
  a single call. Compose (Android) and SwiftUI (iOS) handle diffing and
  rendering internally.

  ## Node format

      %{
        type: :column,
        props: %{padding: 16, background: :surface},
        children: [
          %{type: :text,   props: %{text: "Hello", text_size: :xl, text_color: :on_surface}, children: []},
          %{type: :button, props: %{text: "Tap",   background: :primary, on_tap: self()},    children: []}
        ]
      }

  ## Style tokens

  Atom values for `:background`, `:text_color`, `:border_color`, `:color` are
  resolved against the color palette (e.g. `:primary` → `0xFF2196F3`).

  Atom values for `:text_size` are resolved against the type scale
  (e.g. `:xl` → `20.0`).

  ## Style structs

  A `%Mob.Style{}` value under the `:style` key is merged into the node's
  own props before serialisation. Inline props override style values:

      props: %{style: @header, text_size: :base}   # :base overrides @header's text_size

  ## Platform blocks

  Props scoped to one platform are silently ignored on the other:

      props: %{padding: 12, ios: %{padding: 20}}
      # iOS sees padding: 20; Android sees padding: 12

  ## Injecting a mock NIF

      Mob.Renderer.render(tree, :android, MockNIF)
  """

  alias Mob.Style

  @default_nif :mob_nif

  # ── Token tables ──────────────────────────────────────────────────────────────

  @colors %{
    # Semantic
    primary:    0xFF2196F3,
    surface:    0xFFFFFFFF,
    on_primary: 0xFFFFFFFF,
    on_surface: 0xFF212121,
    error:      0xFFF44336,
    # Basic
    white:       0xFFFFFFFF,
    black:       0xFF000000,
    transparent: 0x00000000,
    # Grays
    gray_100: 0xFFF5F5F5,
    gray_200: 0xFFEEEEEE,
    gray_300: 0xFFE0E0E0,
    gray_400: 0xFFBDBDBD,
    gray_500: 0xFF9E9E9E,
    gray_600: 0xFF757575,
    gray_700: 0xFF616161,
    gray_800: 0xFF424242,
    gray_900: 0xFF212121,
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
    # Reds
    red_400: 0xFFEF5350,
    red_500: 0xFFF44336,
    red_700: 0xFFD32F2F,
    # Oranges / Amber
    orange_400: 0xFFFFA726,
    orange_500: 0xFFFF9800,
    amber_700:  0xFFF57C00,
    # Purples / Indigo
    purple_500:      0xFF9C27B0,
    purple_700:      0xFF7B1FA2,
    indigo_500:      0xFF3F51B5,
    deep_purple_700: 0xFF512DA8,
  }

  @text_sizes %{
    xs:    12.0,
    sm:    14.0,
    base:  16.0,
    lg:    18.0,
    xl:    20.0,
    "2xl": 24.0,
    "3xl": 30.0,
    "4xl": 36.0,
    "5xl": 48.0,
    "6xl": 60.0,
  }

  @color_props  ~w(background text_color border_color color placeholder_color)a
  @size_props   ~w(text_size font_size)a

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Render a component tree for the given platform.

  Clears the tap registry, serializes the tree to JSON, and calls `set_root/1`
  on the NIF. Returns `{:ok, :json_tree}`.

  `transition` is an atom (`:push`, `:pop`, `:reset`, `:none`) for the nav
  animation. Defaults to `:none` (instant swap).
  """
  @spec render(map(), atom(), module() | atom(), atom()) :: {:ok, :json_tree} | {:error, term()}
  def render(tree, platform, nif \\ @default_nif, transition \\ :none) do
    nif.clear_taps()
    nif.set_transition(transition)

    json =
      tree
      |> prepare(nif, platform)
      |> :json.encode()
      |> IO.iodata_to_binary()

    nif.set_root(json)
    {:ok, :json_tree}
  end

  @doc "Return the full color palette map (token → ARGB integer)."
  def colors, do: @colors

  @doc "Return the text-size scale map (token → float sp)."
  def text_sizes, do: @text_sizes

  # ── Tree preparation ──────────────────────────────────────────────────────────

  defp prepare(%{type: type, props: props, children: children}, nif, platform) do
    %{
      "type"     => Atom.to_string(type),
      "props"    => prepare_props(props, nif, platform),
      "children" => Enum.map(children, &prepare(&1, nif, platform))
    }
  end

  defp prepare_props(props, nif, platform) do
    # 1. Merge any %Mob.Style{} under the :style key (inline props win)
    {style, base} = Map.pop(props, :style)
    merged =
      case style do
        %Style{props: sp} -> Map.merge(sp, base)
        nil               -> base
      end

    # 2. Resolve platform blocks (:ios / :android)
    ios_extras     = Map.get(merged, :ios, %{})
    android_extras = Map.get(merged, :android, %{})
    platform_extra = if platform == :ios, do: ios_extras, else: android_extras
    final =
      merged
      |> Map.delete(:ios)
      |> Map.delete(:android)
      |> Map.merge(platform_extra)

    # 3. Serialize: convert atom keys, register taps/changes, resolve tokens
    Map.new(final, fn
      {:on_tap, pid} when is_pid(pid) ->
        {"on_tap", nif.register_tap(pid)}

      {:on_tap, {pid, tag}} when is_pid(pid) ->
        {"on_tap", nif.register_tap({pid, tag})}

      {:on_change, {pid, tag}} when is_pid(pid) ->
        # Reuses the same handle registry as taps; the C side decides what
        # message type to send (tap vs change) based on which function is called.
        {"on_change", nif.register_tap({pid, tag})}

      {:on_focus, {pid, tag}} when is_pid(pid) ->
        {"on_focus", nif.register_tap({pid, tag})}

      {:on_blur, {pid, tag}} when is_pid(pid) ->
        {"on_blur", nif.register_tap({pid, tag})}

      {:on_submit, {pid, tag}} when is_pid(pid) ->
        {"on_submit", nif.register_tap({pid, tag})}

      {:on_end_reached, {pid, tag}} when is_pid(pid) ->
        {"on_end_reached", nif.register_tap({pid, tag})}

      {key, value} ->
        {Atom.to_string(key), resolve_token(key, value)}
    end)
  end

  # Resolve atom tokens for known prop types; leave everything else alone.
  defp resolve_token(key, value) when is_atom(value) and key in @color_props do
    Map.get(@colors, value, value)
  end

  defp resolve_token(key, value) when is_atom(value) and key in @size_props do
    Map.get(@text_sizes, value, value)
  end

  defp resolve_token(_key, value), do: value
end
