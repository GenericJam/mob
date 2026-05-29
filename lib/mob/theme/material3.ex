defmodule Mob.Theme.Material3 do
  @moduledoc """
  Material 3 (Material You) theme — cross-platform-consistent design
  system based on Google's Material Design 3 token specification.

  Where Mob's other themes (Light, Dark, Birch, Citrus, Obsidian) pick
  *colors* and let each platform render with its own conventions, this
  theme overrides platform defaults so iOS and Android apps look the
  same: same color tokens, same typography scale, same shape system,
  same elevation rules.

  ## When to use this

  Use Material 3 when **cross-platform visual consistency** matters
  more than feeling native on each platform. iOS apps using this
  theme will look material-y rather than Apple-y — buttons get
  material shapes, type uses the material type scale, elevation is
  tonal-color overlay rather than iOS-style shadow.

  Use one of the platform-respectful themes (Light, Dark) when
  native feel matters more than cross-platform parity.

  ## Source

  Token values are transcribed from Google's published Material 3
  spec at https://m3.material.io/styles. The Compose Material 3
  library (`androidx.compose.material3`) is the reference
  implementation; this module mirrors its baseline color scheme +
  type scale + shape system.

  ## Usage

      defmodule MyApp.App do
        use Mob.App, theme: Mob.Theme.Material3
      end

  Override individual tokens:

      use Mob.App, theme: {Mob.Theme.Material3, primary: 0xFFE91E63}

  ## What this maps onto Mob.Theme today

  Mob.Theme's struct is smaller than the full M3 token surface
  (M3 has tiered surface-container colors, an elevation scale,
  a 5-tier type scale, a shape scale). For Phase 1 we map M3 tokens
  onto the closest existing Mob.Theme fields and document the gaps
  below. Phase 2 (visual fidelity) extends `Mob.Theme`'s struct with
  the missing fields and wires them through the renderer.

  Today's mapping:

  - `primary` / `on_primary` — M3 primary (purple-ish baseline)
  - `secondary` / `on_secondary` — M3 secondary
  - `background` / `on_background` — M3 surface (light mode background)
  - `surface` / `on_surface` — M3 surface-container
  - `surface_raised` — M3 surface-container-high (one tier up)
  - `muted` — M3 on-surface-variant
  - `border` — M3 outline-variant
  - `error` / `on_error` — M3 error
  - `radius_sm` / `_md` / `_lg` / `_pill` — M3 shape scale extra-small,
    small, medium, full

  Gaps (no field in Mob.Theme yet — Phase 2 work):

  - Tonal-color elevation levels (M3 uses surface-color-at-elevation
    rather than shadows; needs new struct field)
  - Surface-container-lowest / -low / -high / -highest tiers
    (currently collapsed to surface + surface_raised)
  - Type scale (M3 has display-{l,m,s}, headline-{l,m,s},
    title-{l,m,s}, body-{l,m,s}, label-{l,m,s} — 15 type roles;
    Mob currently uses `type_scale` as a single multiplier)
  - Shape scale extra-large + extra-extra-large
  - Motion duration + easing tokens

  This module returns the closest-fit translation today; the visual
  polish round will fill in the gaps.
  """

  @doc """
  Returns the compiled Material 3 light theme struct.

  Dark variant lives in `Mob.Theme.Material3.Dark`.
  """
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand (M3 baseline color scheme — purple) ───────────────────────
      # primary = #6750A4 — the canonical M3 baseline purple
      primary: 0xFF6750A4,
      on_primary: 0xFFFFFFFF,
      secondary: 0xFF625B71,
      on_secondary: 0xFFFFFFFF,

      # ── Surfaces ─────────────────────────────────────────────────────────
      # background = M3 surface = #FEF7FF (warm neutral, slight purple tint)
      background: 0xFFFEF7FF,
      on_background: 0xFF1D1B20,
      # surface = M3 surface-container = #F3EDF7
      surface: 0xFFF3EDF7,
      # surface_raised = M3 surface-container-high = #ECE6F0
      surface_raised: 0xFFECE6F0,
      on_surface: 0xFF1D1B20,

      # ── Auxiliary ────────────────────────────────────────────────────────
      # muted = M3 on-surface-variant
      muted: 0xFF49454F,
      # border = M3 outline-variant
      border: 0xFFCAC4D0,

      # ── Errors ───────────────────────────────────────────────────────────
      error: 0xFFB3261E,
      on_error: 0xFFFFFFFF,

      # ── Scale ────────────────────────────────────────────────────────────
      # M3's type scale baseline aligns with mob's 1.0 default.
      # Phase 2 will introduce per-role type tokens (display/headline/etc).
      type_scale: 1.0,
      space_scale: 1.0,

      # ── Shape scale (M3) ─────────────────────────────────────────────────
      # M3 shape tokens (per https://m3.material.io/styles/shape/shape-scale-tokens):
      #   extra-small: 4dp   →  radius_sm
      #   small:       8dp   →  (no mob token today; phase 2)
      #   medium:      12dp  →  radius_md
      #   large:       16dp  →  radius_lg
      #   extra-large: 28dp  →  (no mob token today)
      #   full:        9999  →  radius_pill
      radius_sm: 4,
      radius_md: 12,
      radius_lg: 16,
      radius_pill: 9999
    )
  end

  @doc """
  M3-spec tonal-elevation color stops, indexed by level (0-5).

  Used by Phase 2 renderer integration to apply tonal overlay on
  surfaces — M3's analog to iOS shadow elevation. Each level adds
  more primary-color tint to the base surface.

  Indexed by `dp` of "elevation": 0, 1, 3, 6, 8, 12. Returned as
  the resolved color stop (already-blended primary-tinted surface).

  Phase 2: wire this into the renderer for `<Card>` / `<Box>` with
  `material: :elevated` so an elevated surface renders with the
  correct tonal overlay rather than a fake shadow.
  """
  @spec elevation_color(0..5) :: non_neg_integer()
  def elevation_color(0), do: 0xFFFEF7FF
  def elevation_color(1), do: 0xFFF7F2FA
  def elevation_color(2), do: 0xFFF3EDF7
  def elevation_color(3), do: 0xFFEEE8F4
  def elevation_color(4), do: 0xFFECE6F0
  def elevation_color(5), do: 0xFFE6E0E9

  @doc """
  M3 type-scale role definitions.

  Each role returns `%{size: pt, line_height: pt, weight: integer}`.
  Phase 2: extend the renderer to accept a `text_role:` prop on
  Text components that resolves through this table.
  """
  @spec type_role(atom()) :: %{size: number(), line_height: number(), weight: non_neg_integer()}
  def type_role(:display_large), do: %{size: 57, line_height: 64, weight: 400}
  def type_role(:display_medium), do: %{size: 45, line_height: 52, weight: 400}
  def type_role(:display_small), do: %{size: 36, line_height: 44, weight: 400}
  def type_role(:headline_large), do: %{size: 32, line_height: 40, weight: 400}
  def type_role(:headline_medium), do: %{size: 28, line_height: 36, weight: 400}
  def type_role(:headline_small), do: %{size: 24, line_height: 32, weight: 400}
  def type_role(:title_large), do: %{size: 22, line_height: 28, weight: 400}
  def type_role(:title_medium), do: %{size: 16, line_height: 24, weight: 500}
  def type_role(:title_small), do: %{size: 14, line_height: 20, weight: 500}
  def type_role(:body_large), do: %{size: 16, line_height: 24, weight: 400}
  def type_role(:body_medium), do: %{size: 14, line_height: 20, weight: 400}
  def type_role(:body_small), do: %{size: 12, line_height: 16, weight: 400}
  def type_role(:label_large), do: %{size: 14, line_height: 20, weight: 500}
  def type_role(:label_medium), do: %{size: 12, line_height: 16, weight: 500}
  def type_role(:label_small), do: %{size: 11, line_height: 16, weight: 500}

  @doc """
  M3 shape-scale corner radii (dp).
  """
  @spec shape(atom()) :: non_neg_integer()
  def shape(:extra_small), do: 4
  def shape(:small), do: 8
  def shape(:medium), do: 12
  def shape(:large), do: 16
  def shape(:extra_large), do: 28
  def shape(:full), do: 9999
end
