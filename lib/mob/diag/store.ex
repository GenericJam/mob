defmodule Mob.Diag.Store do
  @moduledoc """
  The owner and lifecycle every diagnostic store shares.

  `Mob.Agent.Receipts`, `Mob.Defect.Bus`, `Mob.Invariant`,
  `Mob.PostMortem.Registry` and `Mob.RenderStats` keep what they record in
  public named ETS tables that callers write directly, with no mailbox on the
  hot path. A table dies with the process that created it, so each needs an
  owner that outlives its writers. They used to carry five hand-written copies
  of that owner, and all of them had the same hole: `GenServer.start/3`
  registers the name before `init/1` runs, so a second concurrent first caller
  got `{:error, {:already_started, pid}}` and wrote to a table that did not
  exist yet. Measured: up to 1,400 of 1,600 concurrent first calls saw no table.

  This module is that owner, once, with the properties a diagnostic needs:

    * **Ready means ready.** `ensure/1` returns only after the store's tables
      exist. The hot path is a single `:ets.whereis/1` on the store's flag table,
      which is created last; only a miss pays for a call to the owner, and that
      call queues behind `init/1`.
    * **Evidence outlives its owner.** Tables are created with
      `Mob.Diag.Heir` as their ETS heir. If an owner dies, its tables and rows
      pass to the heir and stay writable; the next owner takes them back. The
      owner re-points the heir if the heir itself restarts.
    * **Setup is idempotent.** It creates only what is missing, and a store's
      state (counters, sequence numbers) is carried into the new state, so
      `reload/1` re-reads configuration without resetting counters.
    * **State is versioned.** Code loaded by a hot push can change a store's
      state shape; `state/1` notices the version change and re-runs setup, so
      the first write after `mix mob.push` gets state it can read.
    * **Writes never raise and never lose silently.** `guard/3` catches any
      failure on a write path, counts it (`lost`), repairs missing tables, and
      returns a fallback. `health/1` reports `lost`, `resets` (tables recreated
      after being lost) and `owner_starts`.

  A store module implements the callbacks below. The owner is registered as
  `Mob.Diag.Owner.<Store>`, started on first use, and unlinked: `mob` has no
  supervision tree of its own, and a diagnostic must neither die with a writer
  nor take one down. The name is deliberately not the `<Store>.Owner` the
  hand-written owners used: an app that hot-pushes this over an older `mob`
  still has those processes running, and calling into one would crash. Here
  their tables are simply held by `:other` and written to until the app
  restarts.
  """

  use GenServer

  require Logger

  @doc "The store's tables, in creation order. The **last** is the flag `ensure/1` checks."
  @callback tables() :: [{atom(), list()}]

  @doc "Version of the map `new_state/1` returns. Bump it when that shape changes."
  @callback state_vsn() :: pos_integer()

  @doc """
  The store's state, given what was there before (`nil` the first time).

  Must carry counters over from `previous` rather than replacing them, and must
  tolerate a `previous` of an older shape (after a hot push).
  """
  @callback new_state(previous :: map() | nil) :: map()

  @doc "Runs in the owner after every setup, once all tables exist."
  @callback after_setup() :: :ok

  @doc "Store-specific, value-free fields for `health/1`."
  @callback health(state :: map()) :: map()

  @optional_callbacks after_setup: 0, health: 1

  # Generic counters, one `:atomics` array per store kept in its state entry so
  # they survive owner and heir restarts.
  @lost 1
  @resets 2
  @owner_starts 3

  # ── Hot path ─────────────────────────────────────────────────────────────

  @doc "Return once `store`'s tables exist."
  @spec ensure(module()) :: :ok
  def ensure(store) do
    if :ets.whereis(flag_table(store)) == :undefined, do: sync(store)
    :ok
  end

  @doc "The store's current state, re-running setup first if its version is stale."
  @spec state(module()) :: map()
  def state(store) do
    vsn = store.state_vsn()

    case :persistent_term.get(key(store), nil) do
      %{vsn: ^vsn, data: data} ->
        data

      _stale_or_missing ->
        sync(store)
        :persistent_term.get(key(store)).data
    end
  end

  @doc """
  Run a write path. Any failure is counted as lost, logged the first time, and
  followed by a repair of missing tables; `fallback` is returned instead.
  """
  @spec guard(module(), term(), (-> term())) :: term()
  def guard(store, fallback, fun) do
    fun.()
  catch
    # A diagnostic write must never be the reason its caller fails: it runs
    # inside screen callbacks, teardown and crash reporting. Every failure is
    # counted and reported by `health/1` rather than swallowed.
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    kind, reason ->
      note_lost(store, kind, reason)
      repair(store)
      fallback
  end

  @doc "Count one write lost by `store`, outside `guard/3`."
  @spec note_lost(module(), atom(), term()) :: :ok
  def note_lost(store, kind, reason) do
    case :persistent_term.get(key(store), nil) do
      %{counters: counters} ->
        if :atomics.add_get(counters, @lost, 1) == 1 do
          Logger.warning(
            "[Mob.Diag] #{inspect(store)} lost a write: #{inspect(kind)} " <>
              "#{inspect(reason, limit: 8)}. Further losses are counted in " <>
              "Mob.Diag.health/0 without logging."
          )
        end

      nil ->
        :ok
    end

    :ok
  end

  @doc "Re-run setup: create anything missing and re-read configuration, keeping counters."
  @spec reload(module()) :: :ok
  def reload(store), do: sync(store)

  # ── Readback ─────────────────────────────────────────────────────────────

  @doc """
  Value-free health of `store`. Read-only: never starts an owner or creates a
  table, so it reports a broken store instead of repairing it.
  """
  @spec health(module()) :: map()
  def health(store) do
    entry = :persistent_term.get(key(store), nil)
    owner = Process.whereis(owner_name(store))
    heir = Process.whereis(Mob.Diag.Heir)

    base = %{
      owner: owner,
      state_vsn: %{current: entry && entry.vsn, expected: store.state_vsn()},
      lost: counter(entry, @lost),
      resets: counter(entry, @resets),
      owner_starts: counter(entry, @owner_starts),
      tables: Enum.map(store.tables(), fn {name, _} -> table_health(name, owner, heir) end)
    }

    if entry && function_exported?(store, :health, 1),
      do: Map.put(base, :store, store.health(entry.data)),
      else: base
  end

  defp counter(nil, _i), do: 0
  defp counter(%{counters: c}, i), do: :atomics.get(c, i)

  defp table_health(name, owner, heir) do
    case :ets.info(name, :owner) do
      :undefined ->
        %{name: name, held_by: :missing, size: 0}

      pid ->
        held_by =
          cond do
            pid == owner -> :owner
            pid == heir -> :heir
            true -> :other
          end

        %{name: name, held_by: held_by, size: :ets.info(name, :size)}
    end
  end

  # ── Owner ────────────────────────────────────────────────────────────────

  @doc false
  @spec owner_name(module()) :: atom()
  def owner_name(store), do: Module.concat(Mob.Diag.Owner, store)

  defp key(store), do: {__MODULE__, store}

  defp flag_table(store), do: store.tables() |> List.last() |> elem(0)

  # Called from the owner itself (a store's `after_setup/0` writing to its own
  # tables), a call would deadlock; the owner is already running setup.
  defp sync(store) do
    if Process.whereis(owner_name(store)) == self() do
      setup(store)
    else
      {:ok, pid} = start(store)
      GenServer.call(pid, :ensure, :infinity)
    end
  end

  # Repair only when something is actually missing: a write path that fails
  # for another reason must not turn every later write into an owner call.
  defp repair(store) do
    if Enum.any?(store.tables(), fn {name, _} -> :ets.whereis(name) == :undefined end),
      do: sync(store)

    :ok
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _kind, _reason -> :ok
  end

  defp start(store) do
    case GenServer.start(__MODULE__, store, name: owner_name(store)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl GenServer
  def init(store) do
    heir = Mob.Diag.Heir.ensure()
    state = %{store: store, heir: heir, heir_ref: Process.monitor(heir)}
    setup(store, heir)
    bump(store, @owner_starts)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:ensure, _from, state) do
    setup(state.store, state.heir)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}

  # The heir died: tables it was named for would now be deleted with this
  # owner. Name a new one.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{heir_ref: ref} = state) do
    heir = Mob.Diag.Heir.ensure()

    for {name, _} <- state.store.tables(), :ets.info(name, :owner) == self() do
      :ets.setopts(name, {:heir, heir, state.store})
    end

    {:noreply, %{state | heir: heir, heir_ref: Process.monitor(heir)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp setup(store), do: setup(store, Mob.Diag.Heir.ensure())

  # State before tables, and the flag table last: the reverse leaves a window
  # in which a caller sees the flag, skips `ensure/1`'s call, and reads state
  # that is not there yet.
  defp setup(store, heir) do
    previous = :persistent_term.get(key(store), nil)
    publish_state(store, previous)

    if previous && Enum.any?(store.tables(), fn {n, _} -> :ets.whereis(n) == :undefined end),
      do: bump(store, @resets)

    for {name, opts} <- store.tables(), do: own_table(store, name, opts, heir)

    if function_exported?(store, :after_setup, 0), do: store.after_setup()
    :ok
  end

  # `:persistent_term.put/2` on an existing key costs a global scan, so only
  # write when the state actually changed.
  defp publish_state(store, previous) do
    vsn = store.state_vsn()
    counters = (previous && previous[:counters]) || :atomics.new(3, signed: false)
    data = store.new_state(previous && previous[:data])
    entry = %{vsn: vsn, counters: counters, data: data}

    if entry != previous, do: :persistent_term.put(key(store), entry)
  end

  defp own_table(store, name, opts, heir) do
    case :ets.info(name, :owner) do
      :undefined ->
        :ets.new(name, [:named_table, {:heir, heir, store} | opts])

      owner when owner == self() ->
        :ets.setopts(name, {:heir, heir, store})

      ^heir ->
        :ok = Mob.Diag.Heir.give_back(name, self())
        :ets.setopts(name, {:heir, heir, store})

      _other ->
        # Held by a process that is neither us nor the heir. Leave it: taking
        # it is not ours to do, and `health/1` reports it as `:other`.
        :ok
    end

    :ok
  end

  defp bump(store, index) do
    :atomics.add(:persistent_term.get(key(store)).counters, index, 1)
  end
end
