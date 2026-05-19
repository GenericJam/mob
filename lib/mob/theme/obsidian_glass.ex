defmodule Mob.Theme.ObsidianGlass do
  @moduledoc """
  Obsidian + Liquid Glass — the Obsidian palette with `glass: true`, so every
  card / sheet renders as a translucent material instead of a solid fill.

  ## Where it shows up

    * **iOS 26+**: real Liquid Glass via `.glassEffect(.regular, in: …)`.
    * **iOS 17–25**: `.ultraThinMaterial` fallback (visually similar, no
      lensing/refraction).
    * **Android**: ignored for now — Compose Material 3 doesn't ship a
      first-class glassy surface yet. Boxes fall back to solid.

  Only surface-style nodes (currently `Box` with a `background:` set) are
  affected. Text, scroll, and layout primitives are untouched.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.ObsidianGlass
      end

  Or switch at runtime:

      Mob.Theme.set(Mob.Theme.ObsidianGlass)

  To revert to the solid Obsidian look:

      Mob.Theme.set(Mob.Theme.Obsidian)
  """

  @doc "Returns the Obsidian palette with `glass: true`."
  @spec theme() :: Mob.Theme.t()
  def theme do
    %{Mob.Theme.Obsidian.theme() | glass: true}
  end
end
