defmodule Mob.Agent.Receipts do
  @moduledoc """
  A bounded record of recent action receipts, and the telemetry bridge.

  Receipts are written on the path of every dispatched event, so this is
  deliberately cheap: one ETS insert into a `:set`, plus a counter, plus an
  eviction every `@keep` writes. No process is involved on the write path — a
  GenServer here would serialise every event in the app through one mailbox,
  which is the opposite of what a diagnostic should cost.

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
  Apps without it pay one `Code.ensure_loaded?/1` per action, cached by the code
  server after the first call.
  """

  @table :mob_agent_receipts
  @state :mob_agent_receipts_state
  @keep 256

  @doc false
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      # State BEFORE the table, and the table is the flag. The reverse order has
      # a window in which a second process sees the table, skips
      # initialisation, and then reads a `:persistent_term` key that does not
      # exist yet — which raises, on the event path, inside the very `catch`
      # clause that is trying to record a crash report. A state entry with no
      # table is harmless; a table with no state is not.
      :persistent_term.put(@state, %{
        seq: :atomics.new(2, signed: false),
        telemetry?: telemetry_available?()
      })

      :ets.new(@table, [:set, :public, :named_table, {:write_concurrency, true}])
    end

    :ok
  rescue
    # Two processes racing to create the same named table: whichever lost is
    # looking at a table the winner already made, which is the desired state.
    ArgumentError -> :ok
  end

  # Resolved once, at startup, and never again. `Code.ensure_loaded?/1` for an
  # ABSENT module is not cached: it is a `gen_server` call into `:code_server`
  # plus a scan of the code path, measured here at ~12us against ~0.04us for a
  # loaded module. `mob` has no `:telemetry` dependency, so absent is the
  # default case — calling it per action would put every event in every app
  # through one global mailbox, which is exactly what this module's docs claim
  # it avoids.
  defp telemetry_available? do
    mod = emitter()
    Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 3)
  end

  # Configurable so the emission path is testable. `mob` has no `:telemetry`
  # dependency, so with the real module the `emit/2` body can never execute
  # under `mix test` — an advertised event shape that nothing verifies.
  defp emitter, do: Application.get_env(:mob, :telemetry_module, :telemetry)

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
    start()
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
    emitter().execute(
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
