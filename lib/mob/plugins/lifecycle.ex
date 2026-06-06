defmodule Mob.Plugins.Lifecycle do
  @moduledoc """
  Dispatches OS foreground/background transitions to the tier-4 plugins'
  `lifecycle.on_resume` / `lifecycle.on_background` hooks.

  Subscribes to `Mob.Device`'s `:app` events and, on `:did_become_active` /
  `:did_enter_background`, invokes each plugin's corresponding MFA. A plugin
  that didn't declare a hook is simply skipped. Supervised by
  `Mob.Plugins.Supervisor`.
  """

  use GenServer

  require Logger

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    Mob.Device.subscribe(:app)
    {:ok, Mob.Plugins.lifecycle()}
  end

  @impl GenServer
  def handle_info({:mob_device, :did_become_active}, lifecycles) do
    run_hooks(lifecycles, :on_resume)
    {:noreply, lifecycles}
  end

  def handle_info({:mob_device, :did_enter_background}, lifecycles) do
    run_hooks(lifecycles, :on_background)
    {:noreply, lifecycles}
  end

  def handle_info(_msg, lifecycles), do: {:noreply, lifecycles}

  defp run_hooks(lifecycles, key) do
    for lc <- lifecycles, mfa = lc[key], not is_nil(mfa) do
      invoke(mfa, lc[:plugin], key)
    end
  end

  # A misbehaving hook must not take down the dispatcher (and with it every
  # other plugin's hooks) — log and continue.
  defp invoke({m, f, a}, plugin, key) do
    apply(m, f, a)
  rescue
    e ->
      Logger.error(
        "[mob_plugins] #{inspect(plugin)} #{key} crashed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end
end
