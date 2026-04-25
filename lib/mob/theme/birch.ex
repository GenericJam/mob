defmodule Mob.Theme.Birch do
  @moduledoc """
  Birch theme for Mob — warm parchment surfaces with a chestnut-brown accent.

  A light warm theme. Calm and readable — works well for content-heavy apps,
  reading interfaces, and anywhere you want a natural, unhurried feel.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Birch
      end

  ## Overrides

      use Mob.App, theme: {Mob.Theme.Birch, primary: :brown_400}

  ## Publishing your own theme

  Any module that exports `theme/0 :: Mob.Theme.t()` works as a Mob theme.
  You can publish yours as a standalone Hex package and users import it the
  same way:

      use Mob.App, theme: AcmeCorp.Theme.Light
  """

  @doc "Returns the compiled Birch theme struct."
  @spec theme() :: Mob.Theme.t()
  def theme do
    Mob.Theme.build(
      # ── Brand ──────────────────────────────────────────────────────────────
      # 0xFF7C4A1E — warm chestnut
      primary: :brown_600,
      # warm cream — readable on chestnut
      on_primary: 0xFFFFF4E8,
      # muted sage green — complements chestnut
      secondary: 0xFF5C7A52,
      # warm cream
      on_secondary: 0xFFFFF4E8,

      # ── Surfaces ───────────────────────────────────────────────────────────
      # warm parchment
      background: 0xFFF5EFE0,
      # dark coffee — high contrast on parchment
      on_background: 0xFF2C1A08,
      # slightly darker warm card
      surface: 0xFFEDE6D5,
      # elevated card
      surface_raised: 0xFFE0D7C3,
      # dark coffee
      on_surface: 0xFF2C1A08,
      # warm gray-brown — placeholders / captions
      muted: 0xFF8A7A6A,

      # ── Utility ────────────────────────────────────────────────────────────
      error: :red_500,
      on_error: :white,
      # warm beige divider
      border: 0xFFCCBCA8
    )
  end
end
