defmodule Mob.Device.IOS do
  @moduledoc """
  iOS-specific device events. Subscribers receive events that either have no
  Android counterpart (e.g. `:protected_data_did_become_available`) or carry
  extra iOS fidelity beyond what `Mob.Device` exposes cross-platform.

  Messages are tagged `:mob_device_ios`:

      {:mob_device_ios, event}
      {:mob_device_ios, event, payload}

  ## Subscribe

      Mob.Device.IOS.subscribe()

  ## Events

  All cross-platform `Mob.Device` events are also re-emitted here under the
  same atom (so users targeting iOS only can subscribe just to this module
  and get the full event set). Plus iOS-only:

  - `:protected_data_will_become_unavailable` — device about to lock; data
    protection class A files become unreadable shortly after.
  - `:protected_data_did_become_available` — device unlocked.
  - `:audio_route_changed` — output route changed (headphones plugged in,
    Bluetooth connected, etc.).

  ## Raw queries

  When `Mob.Device` normalizes values (e.g. thermal `:nominal/:fair/...`),
  this module exposes the raw native values for diagnostics.

      Mob.Device.IOS.raw_thermal_state()  # 0..3 (NSProcessInfoThermalState)
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the calling process to iOS-specific device events."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc "Unsubscribe the calling process."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc """
  Raw `NSProcessInfoThermalState` value (0=nominal, 1=fair, 2=serious, 3=critical).

  Provided for diagnostics. Most code should use `Mob.Device.thermal_state/0`
  which returns a normalized atom shared with Android.
  """
  @spec raw_thermal_state() :: 0 | 1 | 2 | 3
  def raw_thermal_state do
    case Mob.Device.thermal_state() do
      :nominal -> 0
      :fair -> 1
      :serious -> 2
      :critical -> 3
    end
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
  def handle_info({:mob_device_ios, _} = msg, state) do
    fan_out(state, msg)
    {:noreply, state}
  end

  def handle_info({:mob_device_ios, _, _} = msg, state) do
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
