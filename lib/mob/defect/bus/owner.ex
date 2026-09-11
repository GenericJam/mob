defmodule Mob.Defect.Bus.Owner do
  @moduledoc """
  Owns `Mob.Defect.Bus`'s ETS tables and the subscriber registry.

  Same reason `Mob.Invariant.Owner` and `Mob.Agent.Receipts.Owner` exist: an
  ETS table dies with its creator, so a table that outlives the process which
  emitted the first defect has to be owned by something the framework
  controls. Unlinked, so a diagnostic neither dies with an emitter nor takes
  one down.

  Subscribers are stored here (in this process's state) and cached in
  `:persistent_term` for the write path to read without a mailbox
  round-trip. Every subscribed pid is monitored so an exit prunes it out of
  the cache automatically.
  """

  use GenServer

  @classes :mob_defect_classes
  @recent :mob_defect_recent
  @state :mob_defect_state
  @subscribers_key :mob_defect_subscribers

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc false
  @spec subscribe(pid()) :: {:ok, reference()}
  def subscribe(pid) do
    {:ok, _pid} = start()
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc false
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) do
    {:ok, _pid} = start()
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    setup()
    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.monitors, pid) do
      # Idempotent — return a fresh ref for parity with a first-time subscribe,
      # but do not double-monitor.
      {:reply, {:ok, make_ref()}, state}
    else
      ref = Process.monitor(pid)
      state = %{state | monitors: Map.put(state.monitors, pid, ref)}
      publish(state)
      {:reply, {:ok, ref}, state}
    end
  end

  @impl GenServer
  def handle_call({:unsubscribe, pid}, _from, state) do
    state =
      case Map.pop(state.monitors, pid) do
        {nil, _} ->
          state

        {ref, remaining} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: remaining}
      end

    publish(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}
    publish(state)
    {:noreply, state}
  end

  # State (atomics) before the tables and the persistent term, and a table is
  # the flag — the reverse order leaves a window where another process sees a
  # table, skips initialisation, and reads a `:persistent_term` key that is
  # not there yet. Same reasoning as `Mob.Invariant.Owner.setup/0`.
  defp setup do
    :persistent_term.put(@state, %{seq: :atomics.new(1, signed: false)})

    for t <- [@classes, @recent] do
      if :ets.whereis(t) == :undefined do
        :ets.new(t, [:set, :public, :named_table, {:write_concurrency, true}])
      end
    end

    # Empty subscriber list — the write path reads this key with a default of
    # `[]`, so a missing key is not a crash, but publishing it here means the
    # first `subscribe/1` does not have to seed it.
    :persistent_term.put(@subscribers_key, [])

    :ok
  end

  defp publish(state) do
    :persistent_term.put(@subscribers_key, Map.keys(state.monitors))
  end
end
