defmodule Mob.PostMortem.Registry do
  # State keys first so any moduledoc `#{@...}` interpolation resolves.
  @table :mob_post_mortem_seen

  @moduledoc """
  A one-shot record of post-mortem artifacts we have already emitted a
  capsule for.

  ## What it is

  A public ETS set keyed by the artifact's `sha256:...` id. `mark_seen/1`
  returns `true` if the id was new (so a caller should emit), `false` if
  it had already been recorded. That is atomic in one ETS op —
  `:ets.insert_new/2` — so two concurrent sweeps on the same dump cannot
  both emit.

  Not persistent across BEAM restarts. That is deliberate: a fresh BEAM
  should re-emit the dumps it finds on disk, because the recipient of
  those capsules (the defect bus + subscribers) is also fresh. Persisting
  the seen-set would silence the exact restart-and-look-again pattern
  that recovers a defect an earlier BEAM's bus never got to observe.

  Same pattern as `Mob.Agent.Receipts.Owner` and `Mob.Invariant.Owner`:
  the table is `:public` and named, its lifecycle owner is unlinked, and
  the write path never goes through a GenServer mailbox.
  """

  @doc false
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined, do: Mob.PostMortem.Registry.Owner.start()
    :ok
  end

  @doc """
  Record `id` if it is not already present.

  Returns `true` when this call is the first observation (so the caller
  should emit its capsule), `false` when another sweep already recorded it.
  """
  @spec mark_seen(String.t()) :: boolean()
  def mark_seen(id) when is_binary(id) do
    start()
    :ets.insert_new(@table, {id, System.system_time(:millisecond)})
  end

  @doc "True when `id` has been recorded by any prior `mark_seen/1`."
  @spec seen?(String.t()) :: boolean()
  def seen?(id) when is_binary(id) do
    start()

    case :ets.lookup(@table, id) do
      [{^id, _}] -> true
      [] -> false
    end
  end

  @doc "How many artifact ids are currently recorded."
  @spec count() :: non_neg_integer()
  def count do
    start()
    :ets.info(@table, :size)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end
end
