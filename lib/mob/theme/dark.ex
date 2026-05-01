defmodule Mob.Theme.Dark do
  @moduledoc """
  High-contrast greyscale dark theme.

  Designed for low-light / nighttime use where bright screens are blinding.
  Near-black background (not pure black, to avoid OLED smear), light grey
  text, mid-grey accents. Functional first, decorative second.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Dark
      end

  See `Mob.Theme.Adaptive` for a theme that follows the OS-level
  light/dark setting automatically.
  """

  @doc "Returns the compiled Dark theme struct."
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand ──────────────────────────────────────────────────────────────
      # near-white — primary buttons stay readable at low brightness
      primary: 0xFFE6E6E6,
      on_primary: 0xFF0A0A0A,
      # mid grey
      secondary: 0xFF8A8A8A,
      on_secondary: 0xFF0A0A0A,

      # ── Surfaces ───────────────────────────────────────────────────────────
      # near-black, not pure black (avoids OLED smear and feels less harsh)
      background: 0xFF0A0A0A,
      # near-white text — WCAG AAA contrast on near-black
      on_background: 0xFFEEEEEE,
      # dark grey card — subtle separation from background
      surface: 0xFF1A1A1A,
      # slightly lighter card-on-card
      surface_raised: 0xFF2A2A2A,
      on_surface: 0xFFEEEEEE,
      # mid grey — captions, placeholders
      muted: 0xFF888888,

      # ── Utility ────────────────────────────────────────────────────────────
      # brighter red — pops on dark bg without being aggressive
      error: 0xFFEF5350,
      on_error: 0xFF0A0A0A,
      # mid-dark grey — visible divider on dark bg
      border: 0xFF3A3A3A
    )
  end
end
