defmodule Mob.Diag.StoreTest do
  # async: false — these kill and restart the named owners, the shared heir and
  # the subscriber registry, which every other diagnostic test uses too.
  use ExUnit.Case, async: false

  alias Mob.Diag.Store
  alias Mob.Test.ProcessHelpers

  defmodule TestStore do
    @moduledoc false
    @behaviour Mob.Diag.Store

    @impl true
    def tables, do: [{:diag_test_rows, [:set, :public]}, {:diag_test_flag, [:set, :public]}]

    @impl true
    def state_vsn, do: :persistent_term.get({__MODULE__, :vsn}, 2)

    @impl true
    def new_state(previous),
      do: %{n: (previous && previous[:n]) || :atomics.new(1, signed: false), shape: :current}

    @impl true
    def health(%{n: n}), do: %{written: :atomics.get(n, 1)}

    def write(value) do
      Store.guard(__MODULE__, :lost, fn ->
        Store.ensure(__MODULE__)
        :atomics.add(Store.state(__MODULE__).n, 1, 1)
        :ets.insert(:diag_test_rows, {value})
        :ets.insert(:diag_test_flag, {value})
        :ok
      end)
    end
  end

  defp owner(store), do: Process.whereis(Store.owner_name(store))

  defp kill(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    ProcessHelpers.await_exit(pid)
  end

  defp tear_down(store) do
    ProcessHelpers.stop_if_running(Store.owner_name(store))
    for {t, _} <- store.tables(), :ets.whereis(t) != :undefined, do: :ets.delete(t)
  end

  defp held_by(store),
    do: store |> Store.health() |> Map.fetch!(:tables) |> Enum.map(& &1.held_by)

  setup do
    tear_down(TestStore)
    :persistent_term.erase({Store, TestStore})
    :persistent_term.erase({TestStore, :vsn})

    on_exit(fn ->
      tear_down(TestStore)
      :persistent_term.erase({Store, TestStore})
      :persistent_term.erase({TestStore, :vsn})
    end)

    :ok
  end

  describe "readiness" do
    # The bug this module exists for: `GenServer.start/3` registers the name
    # before `init/1`, so a second concurrent first caller took the
    # `:already_started` branch and wrote to a table not yet created. Measured
    # against the old owners: up to 1,400 of 1,600 such calls saw no table.
    for {store, call} <- [
          {Mob.Agent.Receipts, quote(do: Mob.Agent.Receipts.recent())},
          {Mob.Defect.Bus, quote(do: Mob.Defect.Bus.classes())},
          {Mob.Invariant, quote(do: Mob.Invariant.violation_count())},
          {Mob.PostMortem.Registry,
           quote(do: Mob.PostMortem.Registry.mark_seen("id#{System.unique_integer()}"))}
        ] do
      test "concurrent first calls to #{inspect(store)} all see a ready store" do
        store = unquote(store)

        failures =
          for _trial <- 1..30, reduce: [] do
            acc ->
              tear_down(store)
              parent = self()

              pids =
                for _ <- 1..8 do
                  spawn(fn ->
                    receive do
                      :go -> :ok
                    end

                    result =
                      try do
                        {:ok, unquote(call)}
                      rescue
                        e -> {:raised, e.__struct__}
                      end

                    send(parent, {:result, self(), result})
                  end)
                end

              Enum.each(pids, &send(&1, :go))

              results =
                for pid <- pids do
                  receive do
                    {:result, ^pid, result} -> result
                  end
                end

              acc ++
                Enum.reject(
                  results,
                  &match?({:ok, v} when is_list(v) or is_integer(v) or is_boolean(v), &1)
                )
          end

        assert failures == []
      end
    end

    test "ensure/1 returns only once every table exists" do
      :ok = Store.ensure(TestStore)
      assert held_by(TestStore) == [:owner, :owner]
    end
  end

  describe "evidence outlives its owner" do
    test "an owner killed mid-life leaves its rows with the heir, writable, and the next owner reclaims them" do
      :ok = TestStore.write(:before)
      kill(owner(TestStore))

      assert held_by(TestStore) == [:heir, :heir]
      assert :ets.lookup(:diag_test_rows, :before) == [{:before}]
      assert TestStore.write(:while_orphaned) == :ok

      :ok = Store.reload(TestStore)

      assert held_by(TestStore) == [:owner, :owner]
      assert :ets.tab2list(:diag_test_rows) |> Enum.sort() == [{:before}, {:while_orphaned}]

      health = Store.health(TestStore)
      assert health.owner_starts == 2
      assert health.resets == 0
      assert health.store.written == 2
    end

    test "a restarted heir is re-appointed, so a later owner death still keeps the rows" do
      :ok = TestStore.write(:kept)
      old_heir = Process.whereis(Mob.Diag.Heir)
      kill(old_heir)

      ProcessHelpers.eventually(fn ->
        heir = Process.whereis(Mob.Diag.Heir)
        is_pid(heir) and heir != old_heir and :ets.info(:diag_test_rows, :heir) == heir
      end)

      kill(owner(TestStore))
      assert :ets.lookup(:diag_test_rows, :kept) == [{:kept}]
    end

    test "losing owner and heir together is counted as a reset, and the store recovers" do
      :ok = TestStore.write(:gone)
      kill(owner(TestStore))
      kill(Process.whereis(Mob.Diag.Heir))
      assert held_by(TestStore) == [:missing, :missing]

      assert TestStore.write(:after) == :ok

      health = Store.health(TestStore)
      assert health.resets == 1
      assert health.store.written == 2
      assert :ets.tab2list(:diag_test_rows) == [{:after}]
    end
  end

  describe "guard/3" do
    test "a write that fails returns the fallback, is counted as lost, and repairs the missing table" do
      :ok = TestStore.write(:first)
      :ets.delete(:diag_test_rows)

      assert TestStore.write(:dropped) == :lost
      assert Store.health(TestStore).lost == 1
      assert held_by(TestStore) == [:owner, :owner]

      assert TestStore.write(:after_repair) == :ok
      assert Store.health(TestStore).lost == 1
    end

    test "a failure that is not a missing table does not call the owner" do
      :ok = TestStore.write(:first)
      starts = Store.health(TestStore).owner_starts
      :sys.suspend(owner(TestStore))

      # A guard that wrongly called the (suspended) owner would block; bound
      # the wait so that shows up as a failure rather than a hung suite.
      task = Task.async(fn -> Store.guard(TestStore, :fallback, fn -> raise "boom" end) end)

      try do
        assert Task.yield(task, 1_000) == {:ok, :fallback}
      after
        :sys.resume(owner(TestStore))
        Task.shutdown(task, :brutal_kill)
      end

      assert Store.health(TestStore).lost == 1
      assert Store.health(TestStore).owner_starts == starts
    end
  end

  describe "state" do
    test "reload/1 keeps counters" do
      :ok = TestStore.write(:a)
      :ok = TestStore.write(:b)
      :ok = Store.reload(TestStore)

      assert Store.health(TestStore).store.written == 2
    end

    test "a state version change (a hot push) re-runs setup and carries counters over" do
      :ok = TestStore.write(:a)
      :persistent_term.put({TestStore, :vsn}, 3)

      assert %{shape: :current} = Store.state(TestStore)
      assert Store.health(TestStore).state_vsn == %{current: 3, expected: 3}
      assert Store.health(TestStore).store.written == 1
    end
  end

  describe "health/1" do
    test "is read-only: it does not start an owner or create tables" do
      assert Store.health(TestStore).owner == nil
      assert held_by(TestStore) == [:missing, :missing]
      assert owner(TestStore) == nil
    end
  end
end
