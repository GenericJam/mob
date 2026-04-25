defmodule Mob.Theme.Citrus do
  @moduledoc """
  Citrus theme for Mob — warm charcoal with a lime-green accent.

  High-contrast and energetic. Works well for utility apps, dashboards,
  and anywhere you want punchy, readable UI with an earthy warmth.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Citrus
      end

  ## Overrides

      use Mob.App, theme: {Mob.Theme.Citrus, primary: :lime_300}

  ## Publishing your own theme

  Any module that exports `theme/0 :: Mob.Theme.t()` works as a Mob theme.
  You can publish yours as a standalone Hex package and users import it the
  same way:

      use Mob.App, theme: AcmeCorp.Theme.Dark
  """

  @doc "Returns the compiled Citrus theme struct."
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand ──────────────────────────────────────────────────────────────
      # 0xFFA3E635 — bright lime green
      primary: :lime_400,
      # near-black with green tint — max contrast
      on_primary: 0xFF141A00,
      # 0xFFF59E0B — warm amber accent
      secondary: :amber_500,
      # near-black with warm tint
      on_secondary: 0xFF1A1000,

      # ── Surfaces ───────────────────────────────────────────────────────────
      # near-black, olive-tinted
      background: 0xFF111209,
      # warm cream
      on_background: 0xFFF0EDCF,
      # dark warm card background
      surface: 0xFF1C1E0F,
      # slightly elevated card
      surface_raised: 0xFF252715,
      # warm cream
      on_surface: 0xFFF0EDCF,
      # muted olive — placeholder / secondary text
      muted: 0xFF7A7A4A,

      # ── Utility ────────────────────────────────────────────────────────────
      error: :red_400,
      on_error: :white,
      # warm olive-tinted divider
      border: 0xFF323420
    )
  end
end
