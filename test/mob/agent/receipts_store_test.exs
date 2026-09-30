defmodule Mob.Agent.ReceiptsStoreTest do
  use ExUnit.Case, async: false

  alias Mob.Agent.{Receipt, Receipts}

  defmodule StubTelemetry do
    @moduledoc false
    def execute(event, measurements, metadata) do
      send(:receipts_store_test, {:telemetry, event, measurements, metadata})
      :ok
    end
  end

  setup do
    Process.register(self(), :receipts_store_test)
    Receipts.reset()
    on_exit(fn -> Application.delete_env(:mob, :telemetry_module) end)
    :ok
  end

  defp receipt(n) do
    %Receipt{
      action_id: "id-#{n}",
      screen: My.Screen,
      handler: {My.Screen, :handle_event, 3},
      event: "tap-#{n}",
      stages: [:dispatched, :handled],
      elapsed_us: n
    }
  end

  describe "bounding" do
    test "keeps exactly the documented number and reports what it dropped" do
      # The CHANGELOG and the decision record both state the bound. An
      # off-by-one here means the published number is wrong — the first version
      # settled at 257 because eviction kept the boundary row.
      for n <- 1..600, do: Receipts.record(receipt(n))

      assert Receipts.count() == 256
      assert Receipts.dropped() == 600 - 256
    end

    test "the oldest is gone and the newest is still fetchable" do
      for n <- 1..300, do: Receipts.record(receipt(n))

      assert Receipts.fetch("id-1") == :error
      assert {:ok, %Receipt{event: "tap-300"}} = Receipts.fetch("id-300")
    end

    test "a missing id is distinguishable from a forgotten one" do
      # `fetch/1` returning :error is ambiguous once anything has been evicted.
      # `dropped/0` is what makes "never existed" and "no longer held"
      # separable; a diagnostic that silently forgets is one that lies.
      Receipts.record(receipt(1))

      assert Receipts.dropped() == 0
      assert Receipts.fetch("never-issued") == :error
    end
  end

  describe "table ownership" do
    test "receipts survive the death of the process that recorded the first one" do
      # An ETS table dies with its creator. Creating it lazily from `record/1`
      # made the owner whichever screen dispatched the first event of the app's
      # life, so an ordinary `pop` destroyed every held receipt — at zero, not
      # at 256, with `dropped/0` still reporting 0. Worst case is the headline
      # case: the screen whose handler raises owns the table, and the crash
      # receipt is destroyed microseconds later by the same crash.
      # The spawned process must be the first writer, which is the real
      # situation: whichever screen dispatches the first event of the app's
      # life. Tear down what `setup` built — owner, heir and state — so the
      # store is created from nothing on that first write.
      for name <- [Mob.Diag.Store.owner_name(Receipts), Mob.Diag.Heir] do
        Mob.Test.ProcessHelpers.stop_if_running(name)
      end

      if :ets.whereis(:mob_agent_receipts) != :undefined, do: :ets.delete(:mob_agent_receipts)
      :persistent_term.erase({Mob.Diag.Store, Receipts})

      parent = self()

      recorder =
        spawn(fn ->
          Receipts.record(receipt(1))
          send(parent, :recorded)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :recorded
      ref = Process.monitor(recorder)
      send(recorder, :die)
      assert_receive {:DOWN, ^ref, :process, ^recorder, _}

      assert {:ok, %Receipt{event: "tap-1"}} = Receipts.fetch("id-1"),
             "the receipt died with the process that wrote it"
    end
  end

  describe "ordering" do
    test "recent/1 is newest first" do
      for n <- 1..5, do: Receipts.record(receipt(n))

      assert Enum.map(Receipts.recent(3), & &1.event) == ["tap-5", "tap-4", "tap-3"]
    end

    test "concurrent writers do not share a sequence number" do
      # `:counters.get` then `:counters.add` is not atomic; two screens
      # dispatching at once could be issued the same seq, which breaks ordering
      # and lets eviction delete the wrong row.
      1..200
      |> Task.async_stream(&Receipts.record(receipt(&1)), max_concurrency: 20)
      |> Stream.run()

      assert Receipts.count() == 200
      assert Enum.count(Enum.uniq_by(Receipts.recent(200), & &1.action_id)) == 200
    end

    test "a reload keeps order, the bound and the eviction count" do
      # `reload` used to replace the sequence counter under existing rows, so
      # new receipts were numbered below old ones: the newest stopped being
      # reported as newest, eviction stopped at the wrong row, and `dropped`
      # went back to zero.
      for n <- 1..300, do: Receipts.record(receipt(n))
      dropped = Receipts.dropped()

      Mob.Diag.Store.reload(Receipts)
      for n <- 301..400, do: Receipts.record(receipt(n))

      assert hd(Receipts.recent(1)).event == "tap-400"
      assert Receipts.count() == 256
      assert Receipts.dropped() == dropped + 100
    end
  end

  describe "telemetry" do
    test "emits the advertised event, measurements and metadata" do
      Application.put_env(:mob, :telemetry_module, StubTelemetry)
      # The flag is resolved at setup, so ask the store to re-resolve rather
      # than deleting the table out from under it.
      Mob.Diag.Store.reload(Receipts)

      Receipts.record(%{receipt(7) | stages: [:dispatched, :handled]})

      assert_receive {:telemetry, [:mob, :action, :stop], measurements, metadata}
      assert measurements.duration_us == 7
      assert metadata.action_id == "id-7"
      assert metadata.screen == My.Screen
      assert metadata.effect == :inert
      assert metadata.owner == :app_code
    end

    test "does not emit when no telemetry module is available" do
      Application.put_env(:mob, :telemetry_module, NotALoadedModule)
      Mob.Diag.Store.reload(Receipts)

      Receipts.record(receipt(1))

      refute_receive {:telemetry, _, _, _}, 50
    end
  end
end
