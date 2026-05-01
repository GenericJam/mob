defmodule Mob.Theme.Light do
  @moduledoc """
  High-contrast greyscale light theme.

  Designed for outdoor / high-glare use where saturation hurts readability.
  White background, near-black text, dark grey accents. Functional first,
  decorative second.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Light
      end

  See `Mob.Theme.Adaptive` for a theme that follows the OS-level
  light/dark setting automatically.
  """

  @doc "Returns the compiled Light theme struct."
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand ──────────────────────────────────────────────────────────────
      # near-black — buttons read as solid + decisive in bright sun
      primary: 0xFF1F1F1F,
      on_primary: 0xFFFFFFFF,
      # mid grey — secondary actions
      secondary: 0xFF555555,
      on_secondary: 0xFFFFFFFF,

      # ── Surfaces ───────────────────────────────────────────────────────────
      # pure white background for maximum reflectance / minimum eye strain
      background: 0xFFFFFFFF,
      # near-black text — WCAG AAA contrast on white
      on_background: 0xFF0F0F0F,
      # very light grey card — subtle separation from background
      surface: 0xFFF3F3F3,
      # white card-on-card
      surface_raised: 0xFFFFFFFF,
      on_surface: 0xFF0F0F0F,
      # mid grey — captions, placeholders, "off" states
      muted: 0xFF707070,

      # ── Utility ────────────────────────────────────────────────────────────
      # deep red — readable in sun
      error: 0xFFB71C1C,
      on_error: 0xFFFFFFFF,
      # light grey — visible divider without being noisy
      border: 0xFFD0D0D0
    )
  end
end
