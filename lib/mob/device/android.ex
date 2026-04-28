defmodule Mob.Device.Android do
  @moduledoc """
  Android-specific device events. Symmetrical with `Mob.Device.IOS`.

  Messages are tagged `:mob_device_android`:

      {:mob_device_android, event}
      {:mob_device_android, event, payload}

  ## Subscribe

      Mob.Device.Android.subscribe()

  ## Status

  Android event surfacing is **pending implementation**. The Elixir API is
  stable; subscribing succeeds but no events fire until
  `ProcessLifecycleObserver` and `ComponentCallbacks2` are wired up in the
  generated app's Java/Kotlin side. Tracked in `PLAN.md` under "Native event
  surface — Batch 1".

  ## Planned events

  - `:doze_mode_changed` — Doze mode entered/exited (no iOS counterpart)
  - `:idle_mode_changed` — light idle mode (`ACTION_LIGHT_DEVICE_IDLE_MODE_CHANGED`)
  - `:trim_memory` with level — `ComponentCallbacks2.onTrimMemory(level)`
  - `:airplane_mode_changed` — `ACTION_AIRPLANE_MODE_CHANGED`
  - `:user_present` — `ACTION_USER_PRESENT` (device unlocked)
  - all cross-platform `Mob.Device` events re-emitted under this tag too
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the calling process to Android-specific device events."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc "Unsubscribe the calling process."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{subscribers: %{}, monitors: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = put_subscriber(state, pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    state = drop_subscriber(state, pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:__test_subscribers__, _from, state) do
    {:reply, state.subscribers, state}
  end

  @impl true
  def handle_info({:mob_device_android, _} = msg, state) do
    fan_out(state, msg)
    {:noreply, state}
  end

  def handle_info({:mob_device_android, _, _} = msg, state) do
    fan_out(state, msg)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp put_subscriber(state, pid) do
    monitors =
      case Map.get(state.monitors, pid) do
        nil -> Map.put(state.monitors, pid, Process.monitor(pid))
        _ref -> state.monitors
      end

    %{state | subscribers: Map.put(state.subscribers, pid, true), monitors: monitors}
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.monitors, pid) do
      {nil, monitors} ->
        %{state | monitors: monitors}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.delete(state.subscribers, pid), monitors: monitors}
    end
  end

  defp fan_out(state, msg) do
    Enum.each(state.subscribers, fn {pid, _} -> send(pid, msg) end)
  end
end
