defmodule Mob.Theme.Adaptive do
  @moduledoc """
  Theme that follows the OS-level light / dark setting.

  At call time `theme/0` reads `Mob.Theme.color_scheme/0` and returns
  `Mob.Theme.Light.theme/0` or `Mob.Theme.Dark.theme/0`. Built for
  outdoor working users — sun-readable in daytime, eye-friendly at night.

  ## Usage

      defmodule MyApp do
        use Mob.App, theme: Mob.Theme.Adaptive
      end

  ## Reactive switching

  `Mob.Theme.AdaptiveWatcher` (started by `use Mob.App`) calls
  `Mob.Theme.set(Mob.Theme.Adaptive)` again whenever the OS appearance
  flips, as long as the active theme was set from this module. Setting a
  fixed theme afterwards (another module, a struct, a keyword list) stops
  that until `Mob.Theme.Adaptive` is set again.

  The renderer reads the active theme on each render, so a screen that is
  already showing repaints in the new theme on its next render; the
  watcher does not re-render screens itself.
  """

  @doc "Returns the Light or Dark theme struct based on the current OS appearance."
  @spec theme() :: Mob.Theme.t()
  def theme do
    case Mob.Theme.color_scheme() do
      :dark -> Mob.Theme.Dark.theme()
      _ -> Mob.Theme.Light.theme()
    end
  end
end
