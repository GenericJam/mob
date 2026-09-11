defmodule Mob.PostMortem.Registry.Owner do
  @moduledoc """
  Owns the ETS table `Mob.PostMortem.Registry` writes to.

  Same reason `Mob.Agent.Receipts.Owner` / `Mob.Invariant.Owner` /
  `Mob.Defect.Bus.Owner` exist: an ETS table dies with its creator, and
  the registry needs to outlive the caller that first sweeps. Unlinked,
  so a sweeping process's exit does not take the registry down.
  """

  use GenServer

  @table :mob_post_mortem_seen

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl GenServer
  def init(_opts) do
    # The sibling owners (`Mob.Invariant.Owner`, `Mob.Defect.Bus.Owner`,
    # `Mob.Agent.Receipts.Owner`) publish per-owner state to
    # `:persistent_term` **before** creating the table, so a second
    # process racing on the "does the table exist" check does not read
    # from a not-yet-set key. This registry stores no persistent_term
    # state — its only durable artifact is the ETS set itself — so the
    # ordering does not apply here. Table creation alone is the whole
    # init, and no window exists to guard.
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, {:write_concurrency, true}])
    end

    {:ok, %{}}
  end
end
