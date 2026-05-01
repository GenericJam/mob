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

  `Mob.Theme.set/1` snapshots the theme at call time, so toggling the OS
  appearance after the app has started does not auto-update the rendered
  theme. To re-evaluate, call `Mob.Theme.set(Mob.Theme.Adaptive)` again
  (e.g. in response to a foreground / lifecycle event, or after a planned
  `:color_scheme_changed` device event in a future version).
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
