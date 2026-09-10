defmodule Mob.Agent.Receipts do
  @moduledoc """
  A bounded record of recent action receipts, and the telemetry bridge.

  Receipts are written on the path of every dispatched event, so this is
  deliberately cheap: one ETS insert into a `:set`, one `:atomics.add_get/3`,
  and an eviction check. **No process is involved on the write path** — a
  GenServer in front of the table would serialise every event in the app
  through one mailbox, which is the opposite of what a diagnostic should cost.
  `Mob.Agent.Receipts.Owner` exists only to own the table so it outlives the
  screens that write to it; nothing routes through it.

  ## Bounded, and honest about it

  The table keeps the most recent 256 receipts. An agent
  that drives an action and reads its receipt immediately will always find it;
  one that drives ten thousand actions and then goes looking for the first will
  not. `count/0` reports how many are held and `dropped/0` how many were evicted,
  so "no receipt for that id" can be distinguished from "that id never existed" —
  a diagnostic that silently forgets is a diagnostic that lies.

  ## Telemetry without a dependency

  `mob` has exactly one runtime dependency. Adding `:telemetry` for this would
  double that, on a framework whose whole premise is running on a phone, so
  events are emitted only when the host application already has it loaded.
  Apps with telemetry (most Phoenix-adjacent ones) get:

      [:mob, :action, :stop]

  with measurements `%{duration_us: ..., }` and metadata carrying the receipt.
  The check runs once, in `Mob.Agent.Receipts.Owner`, and the result is read
  from `:persistent_term` thereafter. Doing it per action would be far worse
  than it looks: a *negative* `Code.ensure_loaded?/1` is not cached, so every
  event in every app would make a `gen_server` call into `:code_server` and scan
  the code path.
  """

  @table :mob_agent_receipts
  @state :mob_agent_receipts_state
  @keep 256

  @doc false
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined, do: Mob.Agent.Receipts.Owner.start()
    :ok
  end

  @doc """
  Record `receipt`, evicting the oldest when the table is full.

  Returns the receipt, so this can sit at the end of a pipeline.
  """
  @spec record(Mob.Agent.Receipt.t()) :: Mob.Agent.Receipt.t()
  def record(%Mob.Agent.Receipt{} = receipt) do
    start()
    state = state()
    # `:atomics.add_get/3` in one step. `:counters.get` followed by
    # `:counters.add` is not atomic, so two screens dispatching concurrently
    # could be issued the same sequence number — which breaks `recent/1`'s
    # ordering and lets eviction delete the wrong row.
    seq = :atomics.add_get(state.seq, 1, 1)
    :ets.insert(@table, {receipt.action_id, seq, receipt})
    evict_beyond_keep(state, seq)
    emit(state, receipt)
    receipt
  end

  @doc "The receipt for `action_id`, or `:error` if it is not held."
  @spec fetch(String.t()) :: {:ok, Mob.Agent.Receipt.t()} | :error
  def fetch(action_id) do
    start()

    case :ets.lookup(@table, action_id) do
      [{^action_id, _seq, receipt}] -> {:ok, receipt}
      [] -> :error
    end
  end

  @doc "The most recent receipts, newest first."
  @spec recent(pos_integer()) :: [Mob.Agent.Receipt.t()]
  def recent(limit \\ 20) do
    start()

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_id, seq, _r} -> -seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_id, _seq, receipt} -> receipt end)
  end

  @doc "How many receipts are currently held."
  @spec count() :: non_neg_integer()
  def count do
    start()
    :ets.info(@table, :size)
  end

  @doc """
  How many receipts have been evicted since the table was created.

  Non-zero means `fetch/1` returning `:error` is ambiguous for old ids.
  """
  @spec dropped() :: non_neg_integer()
  def dropped do
    start()
    :atomics.get(state().seq, 2)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    Mob.Agent.Receipts.Owner.reload()
    :ets.delete_all_objects(@table)
    state = state()
    :atomics.put(state.seq, 1, 0)
    :atomics.put(state.seq, 2, 0)
    :ok
  end

  defp state, do: :persistent_term.get(@state)

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
  # Resolved at startup, not per call — see `telemetry_available?/0`.
  defp emit(%{telemetry?: false}, _receipt), do: :ok

  defp emit(%{telemetry?: true}, receipt) do
    # Same lookup the owner used to resolve `telemetry?`, so a test that swaps
    # the module and restarts the owner gets a consistent pair.
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
end
