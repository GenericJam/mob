defmodule Mob.PostMortem.Registry do
  # State keys first so any moduledoc `#{@...}` interpolation resolves.
  @table :mob_post_mortem_seen

  @moduledoc """
  A one-shot record of post-mortem artifacts we have already emitted a
  capsule for.

  ## What it is

  A public ETS set keyed by the artifact's `sha256:...` id. `emit_once/2` runs
  an emit only for an id not recorded yet, and records it atomically first
  (`:ets.insert_new/2`), so two concurrent sweeps on the same dump cannot both
  emit. If the emit then fails, the id is forgotten again, so the next sweep
  retries it rather than treating a report that never went out as delivered.

  Not persistent across BEAM restarts. That is deliberate: a fresh BEAM
  should re-emit the dumps it finds on disk, because the recipient of
  those capsules (the defect bus + subscribers) is also fresh. Persisting
  the seen-set would silence the exact restart-and-look-again pattern
  that recovers a defect an earlier BEAM's bus never got to observe.

  What does persist is `Mob.PostMortem.Journal`: entries the OS hands over only
  once (MetricKit, `ApplicationExitInfo`) are kept there until observed, and a
  fresh BEAM re-emits them through this registry like a dump still on disk.

  The table is owned by a `Mob.Diag.Store` owner, and the write path never
  goes through a GenServer mailbox.
  """

  @behaviour Mob.Diag.Store

  alias Mob.Diag.Store

  @impl Store
  def tables, do: [{@table, [:set, :public, {:write_concurrency, true}]}]

  @impl Store
  def state_vsn, do: 1

  @impl Store
  def new_state(_previous), do: %{}

  @doc false
  @spec start() :: :ok
  def start, do: Store.ensure(__MODULE__)

  @doc """
  Run `emit` for `id` unless it was already recorded, and return its result in
  a list (empty when skipped or failed).

  A failing `emit` is counted as `lost` in `Mob.Diag.health/0` and un-records
  `id`, so an artifact still on disk is retried by the next sweep. Never raises.
  """
  @spec emit_once(String.t(), (-> result)) :: [result] when result: term()
  def emit_once(id, emit) when is_binary(id) and is_function(emit, 0) do
    if mark_seen(id) do
      try do
        [emit.()]
      catch
        # A sweep runs at boot and on resume; one artifact that fails to emit
        # must not take out the artifacts after it.
        # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
        kind, reason ->
          forget(id)
          Store.note_lost(__MODULE__, kind, reason)
          []
      end
    else
      []
    end
  end

  @doc """
  Record `id` if it is not already present.

  Returns `true` when this call is the first observation (so the caller
  should emit its capsule), `false` when another sweep already recorded it.
  If the record itself fails, returns `true`: a duplicate report is better
  than a lost one.
  """
  @spec mark_seen(String.t()) :: boolean()
  def mark_seen(id) when is_binary(id) do
    Store.guard(__MODULE__, true, fn ->
      Store.ensure(__MODULE__)
      :ets.insert_new(@table, {id, System.system_time(:millisecond)})
    end)
  end

  @doc "Forget `id`, so a later sweep emits it again."
  @spec forget(String.t()) :: :ok
  def forget(id) when is_binary(id) do
    Store.guard(__MODULE__, :ok, fn ->
      Store.ensure(__MODULE__)
      :ets.delete(@table, id)
      :ok
    end)
  end

  @doc "True when `id` has been recorded by any prior `mark_seen/1`."
  @spec seen?(String.t()) :: boolean()
  def seen?(id) when is_binary(id) do
    Store.ensure(__MODULE__)

    case :ets.lookup(@table, id) do
      [{^id, _}] -> true
      [] -> false
    end
  end

  @doc "How many artifact ids are currently recorded."
  @spec count() :: non_neg_integer()
  def count do
    Store.ensure(__MODULE__)
    :ets.info(@table, :size)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end
end
