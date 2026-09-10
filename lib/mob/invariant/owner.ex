defmodule Mob.Invariant.Owner do
  @moduledoc """
  Owns the invariant registry and violation tables.

  Same reason `Mob.Agent.Receipts.Owner` exists: an ETS table dies with its
  creator, and creating one lazily from a check that runs inside a screen
  callback makes the owner a screen — so an ordinary navigation pop would take
  the registry and every recorded violation with it. Unlinked, so a diagnostic
  neither dies with a screen nor takes one down.
  """

  use GenServer

  @table :mob_invariants
  @violations :mob_invariant_violations
  @candidates :mob_invariant_candidates
  @state :mob_invariant_state

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc false
  @spec reload() :: :ok
  def reload do
    {:ok, pid} = start()
    GenServer.call(pid, :reload)
  end

  @impl GenServer
  def init(_opts) do
    setup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    setup()
    {:reply, :ok, state}
  end

  # State before the tables, and a table is the flag — the reverse order leaves
  # a window where another process sees a table, skips initialisation, and reads
  # a `:persistent_term` key that is not there yet.
  defp setup do
    :persistent_term.put(@state, %{seq: :atomics.new(1, signed: false)})

    for t <- [@table, @violations, @candidates] do
      if :ets.whereis(t) == :undefined do
        :ets.new(t, [:set, :public, :named_table, {:write_concurrency, true}])
      end
    end

    # Installed here rather than from an app boot hook, because `mob` has no
    # supervision tree of its own — it is a library inside someone else's app.
    # The owner starts on first use, so the built-ins exist whenever the
    # registry does, and an app that never touches an invariant never pays for
    # one. Safe from inside `init/1`: `register/2` calls `Mob.Invariant.start/0`,
    # which sees the table created two lines above and does not re-enter here.
    Mob.Invariant.Builtins.install()

    :ok
  end
end
