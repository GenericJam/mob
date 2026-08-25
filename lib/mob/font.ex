defmodule Mob.Font do
  @moduledoc """
  Font-name utilities backing the theme system's `fonts:` token map — see
  `Mob.Theme` for the `fonts:` / `font_fallback:` fields these support.
  """

  @doc """
  The Android `res/font/` resource name for a font file: lowercase, the
  extension dropped, characters outside `[a-z0-9_]` replaced with `_`
  (Android resource-name rules). `"Georgia.ttf"` → `"georgia"`,
  `"Inter-Regular.otf"` → `"inter_regular"`. A leading non-letter is
  prefixed with `f_` so the name is a valid resource identifier.

  This is the single implementation used both at build time (`mob_dev`'s
  asset planner, when it copies a font file into `res/font/`) and to
  compute the Android half of a `Mob.Theme` font token
  (`Mob.Theme.font/2`) — there is deliberately no second copy anywhere
  that has to be kept in sync by convention. Living here (in `mob` core,
  which ships on-device) rather than in `mob_dev` (dev-only tooling) is
  what lets `Mob.Theme.font/2` — app code, compiled into the release —
  call it directly.
  """
  @spec android_resource_name(String.t()) :: String.t()
  def android_resource_name(filename) do
    base =
      filename
      |> Path.basename(Path.extname(filename))
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    if base =~ ~r/^[a-z]/, do: base, else: "f_" <> base
  end
end
