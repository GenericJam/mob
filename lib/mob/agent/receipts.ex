defmodule Mob.Agent.Receipts do
  @moduledoc """
  A bounded record of recent action receipts, and the telemetry bridge.

  Receipts are written on the path of every dispatched event, so this is
  deliberately cheap: one ETS insert into a `:set`, one `:atomics.add_get/3`,
  and an eviction check. **No process is involved on the write path** — a
  GenServer in front of the table would serialise every event in the app
  through one mailbox, which is the opposite of what a diagnostic should cost.
  The table is owned by a `Mob.Diag.Store` owner so it outlives the screens that
  write to it; nothing routes through it.

  ## Bounded, and honest about it

  The table keeps the most recent 256 receipts. An agent
  that drives an action and reads its receipt immediately will always find it;
  one that drives ten thousand actions and then goes looking for the first will
  not. `count/0` reports how many are held and `dropped/0` how many were evicted,
  so "no receipt for that id" can be distinguished from "that id never existed" —
  a diagnostic that silently forgets is a diagnostic that lies. A receipt that
  could not be recorded at all is counted as `lost` in `Mob.Diag.health/0`.

  ## Telemetry without a dependency

  `mob` has exactly one runtime dependency. Adding `:telemetry` for this would
  double that, on a framework whose whole premise is running on a phone, so
  events are emitted only when the host application already has it loaded.
  Apps with telemetry (most Phoenix-adjacent ones) get:

      [:mob, :action, :stop]

  with measurements `%{duration_us: ..., }` and metadata carrying the receipt.
  The check runs once per store setup and the result is read from the store's
  state thereafter (`Mob.Diag.Store.reload/1` re-runs it). Doing it per action
  would be far worse than it looks: a *negative* `Code.ensure_loaded?/1` is not
  cached, so every event in every app would make a `gen_server` call into
  `:code_server` and scan the code path.
  """

  @behaviour Mob.Diag.Store

  alias Mob.Diag.Store

  @table :mob_agent_receipts
  @keep 256

  @impl Store
  def tables, do: [{@table, [:set, :public, {:write_concurrency, true}]}]

  @impl Store
  def state_vsn, do: 1

  # `seq` is carried over: replacing it under existing rows would restart
  # sequence numbers below the ones already held, so `recent/1` would sort new
  # receipts under old ones and eviction would stop at the wrong row.
  @impl Store
  def new_state(previous) do
    %{
      seq: (previous && previous[:seq]) || :atomics.new(2, signed: false),
      telemetry?: telemetry_available?()
    }
  end

  @impl Store
  def health(%{seq: seq}), do: %{recorded: :atomics.get(seq, 1), evicted: :atomics.get(seq, 2)}

  @doc """
  Record `receipt`, evicting the oldest when the table is full.

  Returns the receipt, so this can sit at the end of a pipeline.
  """
  @spec record(Mob.Agent.Receipt.t()) :: Mob.Agent.Receipt.t()
  def record(%Mob.Agent.Receipt{} = receipt) do
    Store.guard(__MODULE__, receipt, fn ->
      Store.ensure(__MODULE__)
      state = Store.state(__MODULE__)
      # `:atomics.add_get/3` in one step. `:counters.get` followed by
      # `:counters.add` is not atomic, so two screens dispatching concurrently
      # could be issued the same sequence number — which breaks `recent/1`'s
      # ordering and lets eviction delete the wrong row.
      seq = :atomics.add_get(state.seq, 1, 1)
      :ets.insert(@table, {receipt.action_id, seq, receipt})
      evict_beyond_keep(state, seq)
      emit(state, receipt)
      receipt
    end)
  end

  @doc "The receipt for `action_id`, or `:error` if it is not held."
  @spec fetch(String.t()) :: {:ok, Mob.Agent.Receipt.t()} | :error
  def fetch(action_id) do
    Store.ensure(__MODULE__)

    case :ets.lookup(@table, action_id) do
      [{^action_id, _seq, receipt}] -> {:ok, receipt}
      [] -> :error
    end
  end

  @doc "The most recent receipts, newest first."
  @spec recent(pos_integer()) :: [Mob.Agent.Receipt.t()]
  def recent(limit \\ 20) do
    Store.ensure(__MODULE__)

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_id, seq, _r} -> -seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_id, _seq, receipt} -> receipt end)
  end

  @doc "How many receipts are currently held."
  @spec count() :: non_neg_integer()
  def count do
    Store.ensure(__MODULE__)
    :ets.info(@table, :size)
  end

  @doc """
  How many receipts have been evicted since the table was created.

  Non-zero means `fetch/1` returning `:error` is ambiguous for old ids.
  """
  @spec dropped() :: non_neg_integer()
  def dropped do
    Store.ensure(__MODULE__)
    :atomics.get(Store.state(__MODULE__).seq, 2)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    Store.reload(__MODULE__)
    :ets.delete_all_objects(@table)
    state = Store.state(__MODULE__)
    :atomics.put(state.seq, 1, 0)
    :atomics.put(state.seq, 2, 0)
    :ok
  end

  defp evict_beyond_keep(state, seq) do
    if :ets.info(@table, :size) > @keep do
      # `seq - @keep + 1`: the row at exactly `seq - @keep` is the @keep'th
      # newest and must survive. Without the +1 the table settles at @keep + 1.
      cutoff = seq - @keep + 1
      removed = :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
      :atomics.add(state.seq, 2, removed)
    end
  end

  # `:telemetry` is not a dependency of mob — see the moduledoc. Emitting only
  # when the host app has it keeps mob's runtime dependency count at one.
  # Resolved at setup, not per call — see `telemetry_available?/0`.
  defp emit(%{telemetry?: false}, _receipt), do: :ok

  defp emit(%{telemetry?: true}, receipt) do
    # Same lookup `telemetry_available?/0` used, so a test that swaps the module
    # and reloads the store gets a consistent pair.
    emitter = Application.get_env(:mob, :telemetry_module, :telemetry)

    emitter.execute(
      [:mob, :action, :stop],
      %{duration_us: receipt.elapsed_us || 0},
      %{
        action_id: receipt.action_id,
        screen: receipt.screen,
        handler: receipt.handler,
        event: receipt.event,
        effect: Mob.Agent.Receipt.effect(receipt),
        owner: Mob.Agent.Receipt.owner(receipt),
        receipt: receipt
      }
    )

    :ok
  end

  # Resolved at setup, never per action. `Code.ensure_loaded?/1` for an ABSENT
  # module is not cached: it is a `gen_server` call into `:code_server` plus a
  # scan of the code path, measured at ~6-12us against ~0.03us for a loaded one.
  # `mob` has no `:telemetry` dependency, so absent is the default case.
  defp telemetry_available? do
    mod = Application.get_env(:mob, :telemetry_module, :telemetry)
    Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 3)
  end
end
