defmodule Mob.Diag.StoreTest do
  # async: false — these kill and restart the named owners, the shared heir and
  # the subscriber registry, which every other diagnostic test uses too.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Defect.{Bus, Capsule}
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

  defmodule ProbeStore do
    @moduledoc false
    @behaviour Mob.Diag.Store

    @impl true
    def tables, do: [{:diag_probe_rows, [:set, :public]}, {:diag_probe_flag, [:set, :public]}]

    @impl true
    def state_vsn, do: 1

    @impl true
    def new_state(_previous), do: %{}

    # Reports every setup to the test, and dies after taking its tables back
    # when told to: a store whose setup crashes.
    @impl true
    def after_setup do
      if test = :persistent_term.get({__MODULE__, :test}, nil), do: send(test, {:setup, self()})
      if :persistent_term.get({__MODULE__, :crash}, false), do: raise("setup failed")
      :ok
    end
  end

  defp owner(store), do: Process.whereis(Store.owner_name(store))

  defp kill(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    ProcessHelpers.await_exit(pid)
  end

  # Tables first: an owner stopped while it holds them hands them to the heir,
  # which starts another.
  defp tear_down(store) do
    for {t, _} <- store.tables(), :ets.whereis(t) != :undefined, do: :ets.delete(t)
    ProcessHelpers.stop_if_running(Store.owner_name(store))
  end

  # The heir restarts a killed owner. Tests wait for the replacement to hold
  # every table before going on, so it cannot recreate tables under the next
  # test's teardown.
  defp await_replacement(store, dead) do
    ProcessHelpers.eventually(fn ->
      owner = owner(store)
      is_pid(owner) and owner != dead and Enum.all?(held_by(store), &(&1 == :owner))
    end)

    owner(store)
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
        # Write paths are guarded, so a write to a missing table returns its
        # fallback rather than raising; only `lost` can show it happened.
        lost_before = Store.health(store).lost

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
        assert Store.health(store).lost == lost_before
      end
    end

    test "ensure/1 returns only once every table exists" do
      :ok = Store.ensure(TestStore)
      assert held_by(TestStore) == [:owner, :owner]
    end
  end

  describe "evidence outlives its owner" do
    test "every store's killed owner is replaced without any write, keeping its tables and rows" do
      # MOB-302: nothing started the next owner. `ensure/1` only checks that
      # the tables exist, and the heir held them, so on a Moto G the receipts
      # owner stayed down until the heir died too and took every receipt.
      Mob.Agent.Receipts.record(%Mob.Agent.Receipt{
        action_id: "mob-302",
        screen: X,
        handler: {X, :h, 3},
        event: "kept",
        stages: []
      })

      on_exit(&Mob.Agent.Receipts.reset/0)

      stores = Map.keys(Mob.Diag.health().stores)
      for store <- stores, do: Store.ensure(store)
      before = Mob.Diag.health().stores
      for store <- stores, do: kill(before[store].owner)

      ProcessHelpers.eventually(fn ->
        Enum.all?(Mob.Diag.health().stores, fn {store, now} ->
          is_pid(now.owner) and now.owner != before[store].owner and
            Enum.all?(now.tables, &(&1.held_by == :owner))
        end)
      end)

      now = Mob.Diag.health().stores

      for store <- stores do
        assert now[store].owner_starts == before[store].owner_starts + 1
        assert now[store].resets == before[store].resets
        assert Enum.map(now[store].tables, & &1.size) == Enum.map(before[store].tables, & &1.size)
      end

      assert {:ok, %{event: "kept"}} = Mob.Agent.Receipts.fetch("mob-302")
    end

    test "tables stay writable while the heir holds them, and the replacement keeps what was written" do
      :ok = TestStore.write(:before)
      first = owner(TestStore)
      heir = Process.whereis(Mob.Diag.Heir)
      # Held still, the heir cannot restart the owner yet.
      :sys.suspend(heir)

      try do
        kill(first)
        assert held_by(TestStore) == [:heir, :heir]
        assert TestStore.write(:while_orphaned) == :ok
      after
        :sys.resume(heir)
      end

      await_replacement(TestStore, first)
      assert :ets.tab2list(:diag_test_rows) |> Enum.sort() == [{:before}, {:while_orphaned}]

      health = Store.health(TestStore)
      assert health.owner_starts == 2
      assert health.resets == 0
      assert health.store.written == 2
    end

    test "killing the heir once the replacement holds the tables loses nothing" do
      :ok = TestStore.write(:kept)
      first = owner(TestStore)
      kill(first)
      replacement = await_replacement(TestStore, first)

      kill(Process.whereis(Mob.Diag.Heir))

      assert owner(TestStore) == replacement
      assert held_by(TestStore) == [:owner, :owner]
      assert :ets.lookup(:diag_test_rows, :kept) == [{:kept}]
      assert Store.health(TestStore).resets == 0
    end

    test "a restarted heir is re-appointed, so a later owner death still keeps the rows" do
      :ok = TestStore.write(:kept)
      old_heir = Process.whereis(Mob.Diag.Heir)
      kill(old_heir)

      ProcessHelpers.eventually(fn ->
        heir = Process.whereis(Mob.Diag.Heir)
        is_pid(heir) and heir != old_heir and :ets.info(:diag_test_rows, :heir) == heir
      end)

      first = owner(TestStore)
      kill(first)
      await_replacement(TestStore, first)
      assert :ets.lookup(:diag_test_rows, :kept) == [{:kept}]
    end

    test "losing owner and heir together is counted as a reset, and the store recovers" do
      :ok = TestStore.write(:gone)
      heir = Process.whereis(Mob.Diag.Heir)
      # Held still, the heir cannot hand the tables to a replacement first.
      :sys.suspend(heir)
      kill(owner(TestStore))
      kill(heir)
      assert held_by(TestStore) == [:missing, :missing]

      assert TestStore.write(:after) == :ok

      health = Store.health(TestStore)
      assert health.resets == 1
      assert health.store.written == 2
      assert :ets.tab2list(:diag_test_rows) == [{:after}]
    end

    @tag :capture_log
    test "each owner death gets one restart, and an owner that dies in setup gets none" do
      on_exit(fn ->
        tear_down(ProbeStore)

        for key <- [{Store, ProbeStore}, {ProbeStore, :test}, {ProbeStore, :crash}],
            do: :persistent_term.erase(key)
      end)

      :ok = Store.ensure(ProbeStore)
      :ets.insert(:diag_probe_rows, {:kept})
      :persistent_term.put({ProbeStore, :test}, self())

      # Two tables pass to the heir, one message each. A restart per message
      # would set the replacement up twice.
      first = owner(ProbeStore)
      kill(first)
      assert_receive {:setup, second}
      assert await_replacement(ProbeStore, first) == second
      refute_receive {:setup, _}, 100

      # Its replacement takes the tables back and dies, handing them to the
      # heir again. Restarting that would never end.
      :persistent_term.put({ProbeStore, :crash}, true)
      kill(second)
      assert_receive {:setup, third}
      ProcessHelpers.await_exit(third)
      refute_receive {:setup, _}, 200

      assert owner(ProbeStore) == nil
      assert held_by(ProbeStore) == [:heir, :heir]
      assert :ets.lookup(:diag_probe_rows, :kept) == [{:kept}]
    end

    test "tables whose heir data names no store stay with the heir, which keeps restarting the rest" do
      :ok = TestStore.write(:kept)
      heir = Process.whereis(Mob.Diag.Heir)
      former = Module.concat(__MODULE__, FormerStore)
      never = Module.concat(__MODULE__, NeverAStore)

      on_exit(fn ->
        for t <- [:diag_former_rows, :diag_never_a_store],
            :ets.whereis(t) != :undefined,
            do: :ets.delete(t)

        :persistent_term.erase({Store, former})
        :code.delete(former)
        :code.purge(former)
      end)

      # A store a hot push removed: its state and tables outlive its module.
      Module.create(
        former,
        quote do
          @behaviour Mob.Diag.Store
          def tables, do: [{:diag_former_rows, [:set, :public]}]
          def state_vsn, do: 1
          def new_state(_previous), do: %{}
        end,
        Macro.Env.location(__ENV__)
      )

      :ok = Store.ensure(former)
      :ets.insert(:diag_former_rows, {:former})
      :code.delete(former)
      :code.purge(former)

      log =
        capture_log(fn ->
          kill(owner(former))
          parent = self()

          holder =
            spawn(fn ->
              :ets.new(:diag_never_a_store, [:named_table, :public, {:heir, heir, never}])
              send(parent, :held)
              Process.sleep(:infinity)
            end)

          assert_receive :held
          kill(holder)

          first = owner(TestStore)
          kill(first)
          await_replacement(TestStore, first)
        end)

      # Skipped, not attempted and failed.
      refute log =~ inspect(former)

      assert Process.whereis(Mob.Diag.Heir) == heir
      assert :ets.info(:diag_never_a_store, :owner) == heir
      assert :ets.info(:diag_former_rows, :owner) == heir
      assert :ets.lookup(:diag_former_rows, :former) == [{:former}]
      assert owner(former) == nil
      assert :ets.lookup(:diag_test_rows, :kept) == [{:kept}]
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

  describe "hot push onto an older mob" do
    # An older `mob` left its rows in tables this code adopts, its counters
    # under its own keys, and its subscribers where it kept them. None of that
    # may be lost, numbered over, or crash the readback.

    test "a new state continues from the highest sequence already in each table" do
      for store <- [Mob.Agent.Receipts, Bus, Mob.Invariant], do: Store.ensure(store)
      # The seed is the table's maximum, so rows other files left must not count.
      Mob.Agent.Receipts.reset()
      Bus.reset()
      Mob.Invariant.reset()

      receipt = %Mob.Agent.Receipt{
        action_id: "old",
        screen: X,
        handler: {X, :h, 3},
        event: "old",
        stages: []
      }

      capsule =
        Capsule.new(kind: :invariant, owner: :mob, severity: :warning, fingerprint_key: %{old: 1})

      :ets.insert(:mob_agent_receipts, {"old", 700, receipt})
      :ets.insert(:mob_defect_recent, {900, capsule})
      :ets.insert(:mob_invariant_violations, {500, :old_violation})

      on_exit(fn ->
        Mob.Agent.Receipts.reset()
        Bus.reset()
        Mob.Invariant.reset()
      end)

      for store <- [Mob.Agent.Receipts, Bus, Mob.Invariant] do
        :persistent_term.erase({Store, store})
        Store.reload(store)
      end

      assert Store.health(Mob.Agent.Receipts).store.recorded == 700
      assert Store.health(Bus).store.emitted == 900
      assert Store.health(Mob.Invariant).store.confirmed == 500
    end

    test "receipts adopt the eviction count an older mob kept" do
      old = :atomics.new(2, signed: false)
      :atomics.put(old, 2, 44)
      :persistent_term.put(:mob_agent_receipts_state, %{seq: old})

      on_exit(fn ->
        :persistent_term.erase(:mob_agent_receipts_state)
        Mob.Agent.Receipts.reset()
      end)

      :persistent_term.erase({Store, Mob.Agent.Receipts})
      Store.reload(Mob.Agent.Receipts)

      assert Mob.Agent.Receipts.dropped() == 44
    end

    test "subscribers an older mob registered keep receiving" do
      stop_subscribers()
      :persistent_term.put(:mob_defect_subscribers, [self()])
      trace = :ets.new(:mob_event_trace, [:named_table, :public])
      :ets.insert(trace, {self(), nil})

      on_exit(fn ->
        :persistent_term.erase(:mob_defect_subscribers)
        stop_subscribers()
      end)

      capsule =
        Mob.Defect.Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{legacy: 1}
        )

      Mob.Defect.Bus.emit(capsule)
      assert_receive {:mob_defect, ^capsule}

      address = Mob.Event.Address.new(screen: X, widget: :button, id: :legacy)
      Mob.Event.Trace.broadcast(address, :tap, nil)
      assert_receive {:mob_trace, ^address, :tap, nil}

      :ets.delete(trace)
    end

    test "legacy state the registry cannot read never breaks dispatch or tracing" do
      # The old trace table belonged to whoever called `Trace.start/0` and can
      # be gone or unreadable; the bus key can hold anything an older build
      # put there. Trace.broadcast runs inside every Mob.Event.dispatch/4.
      for legacy <- [:private_trace_table, :garbage_bus_key] do
        stop_subscribers()
        parent = self()

        holder =
          spawn(fn ->
            if legacy == :private_trace_table,
              do: :ets.new(:mob_event_trace, [:named_table, :private])

            send(parent, :held)
            Process.sleep(:infinity)
          end)

        assert_receive :held
        if legacy == :garbage_bus_key, do: :persistent_term.put(:mob_defect_subscribers, :garbage)

        address = Mob.Event.Address.new(screen: X, widget: :button, id: legacy)
        assert :ok = Mob.Event.dispatch(self(), address, :tap, nil)
        assert :ok = Mob.Event.dispatch(self(), address, :tap, nil)

        :ok = Mob.Event.Trace.subscribe(self(), nil)
        assert :ok = Mob.Event.dispatch(self(), address, :tap, nil)
        assert_receive {:mob_trace, ^address, :tap, nil}

        Process.exit(holder, :kill)
        ProcessHelpers.await_exit(holder)
        :persistent_term.erase(:mob_defect_subscribers)
      end

      stop_subscribers()
    end

    test "health reports state an older shape cannot be read as stale rather than raising" do
      :ok = TestStore.write(:a)
      entry = :persistent_term.get({Store, TestStore})
      :persistent_term.put({Store, TestStore}, %{entry | vsn: 1, data: %{old_shape: true}})

      assert Store.health(TestStore).store == :stale
      assert %{stores: _} = Mob.Diag.health()
    end
  end

  describe "health/1" do
    test "is read-only: it does not start an owner or create tables" do
      assert Store.health(TestStore).owner == nil
      assert held_by(TestStore) == [:missing, :missing]
      assert owner(TestStore) == nil
    end

    test "a loss before the store's first setup is still counted" do
      assert Store.guard(TestStore, :fallback, fn -> :ets.insert(:diag_test_rows, {:x}) end) ==
               :fallback

      assert Store.health(TestStore).lost == 1
    end

    test "a loss onto tables an older mob still holds, before any state exists, is counted" do
      parent = self()

      holder =
        spawn(fn ->
          for {t, opts} <- TestStore.tables(), do: :ets.new(t, [:named_table | opts])
          send(parent, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held

      on_exit(fn -> Process.exit(holder, :kill) end)

      assert Store.guard(TestStore, :fallback, fn -> raise "boom" end) == :fallback
      assert Store.health(TestStore).lost == 1
    end
  end

  defp stop_subscribers do
    ProcessHelpers.stop_if_running(Mob.Diag.Subscribers)

    for k <- [:topics, :defect_bus, :event_trace],
        do: :persistent_term.erase({Mob.Diag.Subscribers, k})
  end
end
