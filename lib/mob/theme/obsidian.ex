defmodule Mob.Theme.Obsidian do
  @moduledoc """
  Obsidian theme for Mob — deep blacks with a violet accent.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Obsidian
      end

  ## Overrides

  Pass a keyword list as the second element of a tuple to override
  individual tokens while keeping the rest of the Obsidian palette:

      use Mob.App, theme: {Mob.Theme.Obsidian, primary: :rose_500}

  ## Publishing your own theme

  Any module that exports `theme/0 :: Mob.Theme.t()` works as a Mob theme.
  You can publish yours as a standalone Hex package and users import it the
  same way:

      use Mob.App, theme: AcmeCorp.Theme.Dark
  """

  @doc "Returns the compiled Obsidian theme struct."
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand ──────────────────────────────────────────────────────────────
      # 0xFF7C3AED
      primary: :violet_600,
      on_primary: :white,
      # 0xFFA78BFA — lighter for accents/tags
      secondary: :violet_400,
      on_secondary: :white,

      # ── Surfaces ───────────────────────────────────────────────────────────
      # near-black, blue-tinted
      background: 0xFF0D0D1A,
      # lavender-tinted white
      on_background: 0xFFE8E6FF,
      # dark card background
      surface: 0xFF16162A,
      # slightly elevated card
      surface_raised: 0xFF1E1E38,
      on_surface: 0xFFE8E6FF,
      # muted text / placeholders
      muted: 0xFF6B6B8E,

      # ── Utility ────────────────────────────────────────────────────────────
      error: :red_400,
      on_error: :white,
      # subtle purple-tinted divider
      border: 0xFF2D2D4A
    )
  end
end
