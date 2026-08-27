defmodule Mob.Theme do
  @moduledoc """
  Design token system for Mob apps.

  A theme is a compiled `%Mob.Theme{}` struct — a flat map of semantic tokens
  for colors, spacing, radii, and scale factors. The renderer resolves these
  tokens at render time so every component picks up the active theme
  automatically.

  ## Using a named theme

  Named themes are plain modules that export `theme/0`. Pass the module to
  `use Mob.App`:

      use Mob.App, theme: MobThemes.Obsidian   # (the mob_themes style package)

  Override individual tokens without leaving the theme:

      use Mob.App, theme: {MobThemes.Obsidian, primary: :rose_500}

  Anyone can publish a theme as a Hex package — any module with `theme/0`
  returning a `Mob.Theme.t()` works:

      use Mob.App, theme: AcmeCorp.BrandTheme

  ## Building a theme from scratch

  Pass a keyword list of overrides against the neutral base:

      use Mob.App, theme: [primary: :emerald_500, type_scale: 1.1]

  Or change the theme at runtime (e.g. for accessibility or user preference):

      Mob.Theme.set(MobThemes.Obsidian)
      Mob.Theme.set({MobThemes.Obsidian, type_scale: 1.2})
      Mob.Theme.set(primary: :pink_500)

  ## Base theme

  When no theme is set the renderer uses the neutral base — plain dark grays
  with a standard blue primary. Functional, not opinionated. Good enough for
  hello world; swap in a named theme when you want personality.

  ## Token reference

  ### Semantic color tokens

      :primary        — main action colour          (default :blue_500)
      :on_primary     — text/icons on primary        (default :white)
      :secondary      — secondary action colour      (default :gray_600)
      :on_secondary   — text/icons on secondary      (default :white)
      :background     — page/screen background       (default :gray_900)
      :on_background  — text on background           (default :gray_100)
      :surface        — card / sheet background      (default :gray_800)
      :surface_raised — elevated card background     (default :gray_700)
      :on_surface     — text/icons on surface        (default :gray_100)
      :muted          — secondary/placeholder text   (default :gray_500)
      :error          — error state colour           (default :red_500)
      :on_error       — text/icons on error          (default :white)
      :border         — dividers and outlines        (default :gray_700)

  ### Spacing tokens (scaled by `space_scale`)

      :space_xs  →  4 × scale
      :space_sm  →  8 × scale
      :space_md  → 16 × scale
      :space_lg  → 24 × scale
      :space_xl  → 32 × scale

  ### Radius tokens

      :radius_sm   → theme.radius_sm   (default  6)
      :radius_md   → theme.radius_md   (default 10)
      :radius_lg   → theme.radius_lg   (default 16)
      :radius_pill → theme.radius_pill (default 100)

  ### Scale factors

      type_scale:  1.0  # multiply all text sizes by this
      space_scale: 1.0  # multiply all spacing tokens by this

  ### Font tokens

  `fonts` is a name → value map, resolved by the renderer exactly like
  colors (`font: :heading` walks this map, same two-step shape as
  `text_color: :primary`). `:default` is special — set it and the renderer
  injects it automatically onto any node that doesn't specify its own
  `font:`, so the whole app picks up a custom font without repeating it
  everywhere:

      Mob.Theme.set(
        fonts: %{
          default: Mob.Theme.font("Inter-Regular", from_file: "priv/fonts/Inter-Regular.ttf"),
          heading: Mob.Theme.font("Inter-Bold", from_file: "priv/fonts/Inter-Bold.ttf")
        }
      )

      # in render/1:
      %{type: :text, props: %{text: "Section", font: :heading}, children: []}
      %{type: :text, props: %{text: "Body copy"}, children: []}  # gets :default automatically

  `font_fallback` is an ordered list of font names tried, in order, if the
  resolved font can't be loaded on-device. Empty by default (the platform's
  own system-font fallback still applies) — set it when you want an
  explicit intermediate fallback before that.

  A font value is either built with `Mob.Theme.font/2` (recommended — it
  computes the Android name from the actual bundled file) or a bare string
  used as-is on both platforms.
  """

  @type color_value :: atom() | non_neg_integer()

  defstruct [
    # ── Semantic colors ──────────────────────────────────────────────────────
    primary: :blue_500,
    on_primary: :white,
    secondary: :gray_600,
    on_secondary: :white,
    surface: :gray_800,
    surface_raised: :gray_700,
    on_surface: :gray_100,
    muted: :gray_500,
    background: :gray_900,
    on_background: :gray_100,
    error: :red_500,
    on_error: :white,
    border: :gray_700,

    # ── Scale factors ─────────────────────────────────────────────────────
    type_scale: 1.0,
    space_scale: 1.0,

    # ── Corner radii (dp / pt) ─────────────────────────────────────────────
    radius_sm: 6,
    radius_md: 10,
    radius_lg: 16,
    radius_pill: 100,

    # ── Material / effect flags ────────────────────────────────────────────
    # When true, surface-style nodes (currently `Box` with a `background:` set)
    # render with a translucent material instead of a solid fill:
    #
    #   * iOS 26+: Liquid Glass via `.glassEffect()`
    #   * iOS 17–25: graceful fallback to `.ultraThinMaterial` background
    #   * Android: no-op (the flag is plumbed but Material 3's glassy-surface
    #     story isn't first-class yet — left as a follow-up)
    #
    # Off by default; opt in via a preset (`MobThemes.ObsidianGlass`, the mob_themes package) or by
    # passing `glass: true` to `Mob.Theme.build/1`.
    #
    # This is a per-theme *default*. A `glass:` prop on an individual Box wins
    # over it in either direction — `glass: false` keeps a solid fill under a
    # glass theme, `glass: true` opts one Box in without one.
    glass: false,

    # ── Fonts ───────────────────────────────────────────────────────────────
    # Named font tokens, resolved by the renderer exactly like colors —
    # `font: :heading` walks this map at render time. `:default` is special:
    # when set, it's the one token the renderer injects automatically onto
    # any node that doesn't specify its own `font:` prop (see
    # `Mob.Renderer`'s app-wide default injection). Absent `:default` (the
    # neutral base's setting), nothing is injected and text renders in the
    # platform's own system font — unchanged, zero-config behavior.
    #
    # A value is either a `Mob.Font.spec()` (built via `Mob.Theme.font/2`, so
    # the Android resource name is always computed from the actual bundled
    # file rather than hand-typed and risking a mismatch) or a bare string
    # used as-is for both platforms — the escape hatch for a family name
    # that's already identical on both (e.g. a built-in system font name).
    fonts: %{},

    # Ordered list of font names tried, in order, when the resolved primary
    # font can't be loaded on-device (missing file, corrupt asset). Same
    # value shape as a `fonts` entry. Empty by default — native's own font
    # APIs already fall through to the OS system font when a name doesn't
    # resolve, so an empty list still fails safe; this list is for
    # *intermediate* fallbacks an app wants to declare explicitly (e.g. a
    # closely-matched alternate before giving up to the system font).
    font_fallback: []
  ]

  @type font_spec :: %{optional(:ios) => String.t(), optional(:android) => String.t()}
  @type font_value :: font_spec() | String.t()
  @type t :: %__MODULE__{}

  @spacing_base %{
    space_xs: 4,
    space_sm: 8,
    space_md: 16,
    space_lg: 24,
    space_xl: 32
  }

  @doc """
  Build a theme from a keyword list of overrides against the neutral base.

      Mob.Theme.build(primary: :emerald_500, type_scale: 1.1)
  """
  @spec build(keyword()) :: t()
  def build(overrides \\ []), do: struct(__MODULE__, overrides)

  @doc "Return the neutral base theme."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Builds a font token value: the iOS PostScript name as given, paired with
  the Android resource name computed from the bundled file via
  `Mob.Font.android_resource_name/1` — the same function `mob_dev`'s asset
  planner uses when it copies the file into `res/font/`. One computation,
  used on both the build side and the theme side, so the two can't drift
  apart the way a hand-typed Android name could.

      fonts: %{
        heading: Mob.Theme.font("Inter-Bold", from_file: "priv/fonts/Inter-Bold.ttf")
      }
  """
  @spec font(String.t(), from_file: Path.t()) :: font_spec()
  def font(ios_family, opts) when is_binary(ios_family) do
    file = Keyword.fetch!(opts, :from_file)
    %{ios: ios_family, android: Mob.Font.android_resource_name(file)}
  end

  @doc """
  Set the active theme. Accepts:

  - A compiled `%Mob.Theme{}` struct
  - A theme module (any module exporting `theme/0`, e.g. `MobThemes.Obsidian`)
  - A `{module, overrides}` tuple
  - A keyword list of overrides against the neutral base
  """
  @spec set(t() | module() | {module(), keyword()} | keyword()) :: :ok
  def set(%__MODULE__{} = theme) do
    Application.put_env(:mob, :theme, theme)
    notify_native(theme)
    :ok
  end

  def set(mod) when is_atom(mod) do
    set(mod.theme())
  end

  def set({mod, overrides}) when is_atom(mod) and is_list(overrides) do
    set(struct(mod.theme(), overrides))
  end

  def set(overrides) when is_list(overrides) do
    set(build(overrides))
  end

  @doc "Return the currently active theme (or the neutral base if none is set)."
  @spec current() :: t()
  def current, do: Application.get_env(:mob, :theme, default())

  @doc """
  Returns the active theme's palette resolved to ARGB integers — semantic
  tokens (`:primary`, `:on_surface`, …) walked through the theme's color
  map and then through `Mob.Renderer.colors/0`. Used to push concrete
  values to the native side (`Mob.Theme.set/1` does this automatically;
  callers usually don't need to invoke this directly).
  """
  @spec resolved_palette(t()) :: %{atom() => non_neg_integer()}
  def resolved_palette(theme \\ current()) do
    palette = Mob.Renderer.colors()

    theme
    |> color_map()
    |> Map.new(fn {key, value} -> {key, resolve_color(value, palette)} end)
  end

  defp resolve_color(value, palette) when is_atom(value) do
    case Map.get(palette, value) do
      nil -> value
      int -> int
    end
  end

  defp resolve_color(value, _palette) when is_integer(value), do: value
  defp resolve_color(value, _palette), do: value

  # Push the resolved palette + theme flags to the native side so Compose
  # MaterialTheme / SwiftUI environment can follow runtime theme changes.
  # Wrapped in try/rescue/catch because the NIF isn't loaded on the host
  # BEAM (tests, IEx without a device) and we don't want `Mob.Theme.set/1`
  # to crash in those contexts.
  #
  # `_font_fallback` rides the same payload: an ordered list of font names,
  # already resolved to THIS device's platform (native never sees the raw
  # spec map, same principle as the palette already being resolved to ARGB
  # ints before it crosses the NIF boundary). Native tries the node's own
  # resolved font first, then walks this list, before falling through to
  # the OS default — see `MOB_FONTS.md`.
  defp notify_native(theme) do
    platform = safe_platform()

    payload =
      resolved_palette(theme)
      |> Map.put(:_glass, theme.glass)
      |> Map.put(:_font_fallback, resolved_font_fallback(theme, platform))

    json = IO.iodata_to_binary(:json.encode(stringify_keys(payload)))

    try do
      :mob_nif.set_theme(json)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp safe_platform do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  defp resolved_font_fallback(theme, platform) do
    theme
    |> font_fallback_list()
    |> Enum.map(&resolve_font_value(&1, platform))
    |> Enum.reject(&is_nil/1)
  end

  # Mirrors Mob.Renderer's resolve_font/3 (a per-node prop resolver) but
  # scoped to Theme's own narrower need — resolving a font_fallback entry
  # for the JSON payload above, same house pattern as this module already
  # having its own resolve_color/2 alongside the renderer's.
  defp resolve_font_value(%{} = spec, platform),
    do: Map.get(spec, platform) || spec[:ios] || spec[:android]

  defp resolve_font_value(value, _platform) when is_binary(value), do: value
  defp resolve_font_value(_value, _platform), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  @doc """
  Returns the current OS appearance: `:light` or `:dark`.

  Reads from the platform NIF (`UITraitCollection.userInterfaceStyle` on
  iOS, `Configuration.uiMode & UI_MODE_NIGHT_MASK` on Android). Falls back
  to `:light` when running on the host BEAM (no NIF loaded), on platforms
  that don't expose appearance, or on legacy Android apps that haven't
  added `MobBridge.getColorScheme()` yet.
  """
  @spec color_scheme() :: :light | :dark
  def color_scheme do
    case :mob_nif.color_scheme() do
      :dark -> :dark
      _ -> :light
    end
  rescue
    # NIF not loaded (host BEAM), wrong arity, or platform doesn't implement
    _ -> :light
  end

  # ── Token maps (used by Mob.Renderer) ─────────────────────────────────────

  @doc false
  @spec color_map(t()) :: %{atom() => color_value()}
  def color_map(%__MODULE__{} = t) do
    %{
      primary: t.primary,
      on_primary: t.on_primary,
      secondary: t.secondary,
      on_secondary: t.on_secondary,
      surface: t.surface,
      surface_raised: t.surface_raised,
      on_surface: t.on_surface,
      muted: t.muted,
      background: t.background,
      on_background: t.on_background,
      error: t.error,
      on_error: t.on_error,
      border: t.border
    }
  end

  @doc false
  @spec spacing_map(t()) :: %{atom() => non_neg_integer()}
  def spacing_map(%__MODULE__{space_scale: scale}) do
    Map.new(@spacing_base, fn {k, v} -> {k, round(v * scale)} end)
  end

  @doc false
  @spec flags_map(t()) :: %{atom() => boolean()}
  def flags_map(%__MODULE__{glass: glass}), do: %{glass: glass}

  @doc false
  @spec radius_map(t()) :: %{atom() => non_neg_integer()}
  def radius_map(%__MODULE__{} = t) do
    %{
      radius_sm: t.radius_sm,
      radius_md: t.radius_md,
      radius_lg: t.radius_lg,
      radius_pill: t.radius_pill
    }
  end

  @doc false
  @spec fonts_map(t()) :: %{atom() => font_value()}
  def fonts_map(%__MODULE__{fonts: fonts}), do: fonts

  @doc false
  @spec font_fallback_list(t()) :: [font_value()]
  def font_fallback_list(%__MODULE__{font_fallback: list}), do: list
end
