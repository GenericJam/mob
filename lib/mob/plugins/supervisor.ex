defmodule Mob.Plugins.Supervisor do
  @moduledoc """
  Supervises the tier-4 plugins' lifecycle.

  On init it runs each plugin's `lifecycle.on_start` MFA in order (an error
  return bubbles up and fails boot loud, per the spec), then supervises the
  plugins' declared `lifecycle.supervised` child specs alongside the
  `Mob.Plugins.Lifecycle` event dispatcher. Started from `Mob.App.start/0`
  after the host's own `on_start/0`, and only when a plugin declares a
  `:lifecycle` (see `Mob.Plugins.start_lifecycle/0`).
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl Supervisor
  def init(:ok) do
    lifecycles = Mob.Plugins.lifecycle()
    run_on_start!(lifecycles)

    children = supervised_children(lifecycles) ++ [Mob.Plugins.Lifecycle]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp run_on_start!(lifecycles) do
    for %{on_start: {m, f, a}} = lc <- lifecycles do
      case apply(m, f, a) do
        {:error, reason} ->
          raise "plugin #{inspect(lc[:plugin])} on_start failed: #{inspect(reason)}"

        _ok ->
          :ok
      end
    end
  end

  # Flattens every plugin's `lifecycle.supervised` child specs into one list.
  defp supervised_children(lifecycles) do
    for lc <- lifecycles, child <- Map.get(lc, :supervised, []), do: child
  end
end
