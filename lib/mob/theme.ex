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

      use Mob.App, theme: Mob.Theme.Obsidian

  Override individual tokens without leaving the theme:

      use Mob.App, theme: {Mob.Theme.Obsidian, primary: :rose_500}

  Anyone can publish a theme as a Hex package — any module with `theme/0`
  returning a `Mob.Theme.t()` works:

      use Mob.App, theme: AcmeCorp.BrandTheme

  ## Building a theme from scratch

  Pass a keyword list of overrides against the neutral base:

      use Mob.App, theme: [primary: :emerald_500, type_scale: 1.1]

  Or change the theme at runtime (e.g. for accessibility or user preference):

      Mob.Theme.set(Mob.Theme.Obsidian)
      Mob.Theme.set({Mob.Theme.Obsidian, type_scale: 1.2})
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
    radius_pill: 100
  ]

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
  Set the active theme. Accepts:

  - A compiled `%Mob.Theme{}` struct
  - A theme module (`Mob.Theme.Obsidian`)
  - A `{module, overrides}` tuple
  - A keyword list of overrides against the neutral base
  """
  @spec set(t() | module() | {module(), keyword()} | keyword()) :: :ok
  def set(%__MODULE__{} = theme) do
    Application.put_env(:mob, :theme, theme)
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
  @spec radius_map(t()) :: %{atom() => non_neg_integer()}
  def radius_map(%__MODULE__{} = t) do
    %{
      radius_sm: t.radius_sm,
      radius_md: t.radius_md,
      radius_lg: t.radius_lg,
      radius_pill: t.radius_pill
    }
  end
end
