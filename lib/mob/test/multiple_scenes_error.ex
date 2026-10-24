defmodule Mob.Test.MultipleScenesError do
  @moduledoc """
  Raised by a `Mob.Test` helper that addresses "the current screen" when the
  app shows more than one window (`Mob.Scene`) and no `scene:` was given.

  Each window has its own current screen, so there is no single answer, and
  guessing a window would turn a tap meant for one into a silent no-op in
  another. The message lists the live windows; pass one as `scene:`.
  """

  defexception [:node, :function, screens: []]

  @impl Exception
  def message(%{node: node, function: function, screens: screens}) do
    listed =
      Enum.map_join(screens, "\n", fn {scene, module, _pid} ->
        "  #{inspect(scene)} showing #{inspect(module)}"
      end)

    "Mob.Test.#{function}: #{length(screens)} window scenes are live on #{inspect(node)}, " <>
      "each with its own current screen. Pass scene: with one of:\n" <>
      listed <>
      "\nMob.Test.screens/1 lists them."
  end
end
