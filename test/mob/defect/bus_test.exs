defmodule Mob.Defect.BusTest do
  # Not async — the bus is process-global (ETS + persistent_term + a named
  # GenServer), so tests running concurrently would step on each other's
  # subscribers and recent-buffer entries. That is a property of the bus
  # under test, not a bug in it, so isolating with `async: false` is the
  # right knob.
  use ExUnit.Case, async: false

  alias Mob.Defect.Bus
  alias Mob.Defect.Capsule

  setup do
    Bus.start()
    Bus.reset()
    Bus.unsubscribe()
    :ok
  end

  defp invariant_capsule(name, screen \\ MyScreen) do
    Capsule.new(
      kind: :invariant,
      owner: :mob,
      severity: :critical,
      fingerprint_key: %{invariant: name, screen: screen}
    )
  end

  describe "emit/1 — classes" do
    test "creates a class row on first emit with occurrences: 1" do
      c = invariant_capsule(:leaked_component)
      Bus.emit(c)

      assert [row] = Bus.classes()
      assert row.fingerprint == c.fingerprint
      assert row.kind == :invariant
      assert row.owner == :mob
      assert row.severity == :critical
      assert row.occurrences == 1
      assert row.first_capsule == c
    end

    test "increments occurrences for the same fingerprint, not a new row" do
      for _ <- 1..5, do: Bus.emit(invariant_capsule(:leaked_component))

      assert Bus.class_count() == 1
      assert [row] = Bus.classes()
      assert row.occurrences == 5
    end

    test "different fingerprints get different class rows" do
      Bus.emit(invariant_capsule(:leaked_component))
      Bus.emit(invariant_capsule(:parked_screen_alive))
      Bus.emit(invariant_capsule(:leaked_component))

      assert Bus.class_count() == 2
      rows = Bus.classes()
      leaked = Enum.find(rows, &(&1.first_capsule.evidence.invariant == :leaked_component))
      parked = Enum.find(rows, &(&1.first_capsule.evidence.invariant == :parked_screen_alive))
      assert leaked.occurrences == 2
      assert parked.occurrences == 1
    end

    test "class row keeps the first capsule, not the last" do
      first = invariant_capsule(:leaked_component)
      # Make sure the second capsule genuinely differs (different id, later
      # detected_at) so we can prove which one the row kept.
      Process.sleep(2)
      second = invariant_capsule(:leaked_component)

      Bus.emit(first)
      Bus.emit(second)

      assert first.id != second.id

      [row] = Bus.classes()
      assert row.first_capsule.id == first.id
    end

    test "classes come back newest-last-seen first" do
      old = invariant_capsule(:one)
      Bus.emit(old)
      Process.sleep(2)
      newer = invariant_capsule(:two)
      Bus.emit(newer)

      [first, second] = Bus.classes()
      assert first.fingerprint == newer.fingerprint
      assert second.fingerprint == old.fingerprint
    end
  end

  describe "recent/1" do
    test "keeps distinct occurrences of the same class as separate rows" do
      # Two emits with the same fingerprint should collapse in classes but
      # both appear on the recent ring — that is the point of the ring.
      a = invariant_capsule(:leaked_component)
      Bus.emit(a)
      b = invariant_capsule(:leaked_component)
      Bus.emit(b)

      recent = Bus.recent()
      assert length(recent) == 2
      assert Enum.map(recent, & &1.id) == [b.id, a.id]
    end

    test "caps at 64 entries (the bounded ring)" do
      for i <- 1..80, do: Bus.emit(invariant_capsule(:"leaked_#{i}"))

      recent = Bus.recent(200)
      assert length(recent) == 64
    end
  end

  describe "subscribe / unsubscribe" do
    test "a subscriber receives {:mob_defect, capsule}" do
      {:ok, _ref} = Bus.subscribe()
      c = invariant_capsule(:leaked_component)
      Bus.emit(c)
      assert_receive {:mob_defect, ^c}, 500
    end

    test "unsubscribe stops delivery" do
      {:ok, _ref} = Bus.subscribe()
      Bus.emit(invariant_capsule(:before))
      assert_receive {:mob_defect, _}, 500

      Bus.unsubscribe()
      Bus.emit(invariant_capsule(:after_unsub))
      refute_receive {:mob_defect, _}, 100
    end

    test "subscribe/1 is idempotent — one subscriber pid, one delivery" do
      Bus.subscribe()
      Bus.subscribe()
      Bus.emit(invariant_capsule(:double_sub))

      assert_receive {:mob_defect, _}, 500
      refute_receive {:mob_defect, _}, 100
    end

    test "a subscriber that exits is pruned from the fanout list" do
      test_pid = self()

      sub =
        spawn(fn ->
          Bus.subscribe()
          send(test_pid, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed
      assert sub in Bus.subscribers()

      Process.monitor(sub)
      send(sub, :die)
      assert_receive {:DOWN, _, :process, ^sub, _}

      # Give the owner a moment to process the DOWN and republish.
      Process.sleep(20)
      refute sub in Bus.subscribers()
    end

    test "a dead subscriber never seen by fanout does not raise" do
      # send/2 to a dead pid is a no-op, and a change that upgraded fanout
      # to `GenServer.call/2` (a synchronous round-trip that raises `:noproc`
      # on a dead target) would fail this test. `GenServer.cast/2` would
      # not: cast is fire-and-forget on send/2, so this test would not catch
      # a switch to it.
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _}

      # Register the dead pid directly, bypassing the owner's DOWN monitor,
      # so we can observe fanout's behaviour under a stale entry.
      :persistent_term.put(:mob_defect_subscribers, [dead])

      # The emit must not crash.
      Bus.emit(invariant_capsule(:with_dead_sub))

      # Cleanup — remove the manually-injected pid.
      :persistent_term.put(:mob_defect_subscribers, [])
    end

    test "a subscriber slot that would raise on send/2 does not crash the emit" do
      # Standing in for the real failure mode — a remote pid over dist whose
      # payload does not encode, which raises inside `send/2` in the
      # emitter's process. Locally, `send/2` raises on a non-pid target. The
      # try/catch in `fanout/1` isolates any one recipient's failure from
      # the others and from the emitter.
      good_sub = self()

      :persistent_term.put(:mob_defect_subscribers, [:not_a_pid, good_sub])

      capture_log_fn = fn ->
        Bus.emit(invariant_capsule(:with_bad_sub))
      end

      # Emit succeeds despite the raising entry.
      log = ExUnit.CaptureLog.capture_log(capture_log_fn)

      # The good subscriber still received its message.
      assert_receive {:mob_defect, _}, 500

      # The bad slot's failure was surfaced at :error.
      assert log =~ "[error]"
      assert log =~ "Mob.Defect.Bus"

      :persistent_term.put(:mob_defect_subscribers, [])
    end
  end

  describe "under concurrency" do
    test "classes/1 occurrences equals the total number of emits" do
      # `record_class/1` used to refresh a derived-row cache with a
      # read-modify-write, which under contention could clobber a fresh
      # counter with a stale one and leave `classes/1` reporting a lower
      # occurrences count than the actual number of emits. The write path
      # now touches only the two atomic fields (position 3 counter and
      # position 4 last_seen); `classes/1` overlays them on read.
      #
      # This stresses the property: 8 concurrent tasks each emit 100 times
      # against the same fingerprint, and the final occurrences must equal
      # 800 with no other bookkeeping.
      workers = 8
      per_worker = 100

      tasks =
        for _ <- 1..workers do
          Task.async(fn ->
            for _ <- 1..per_worker do
              Bus.emit(invariant_capsule(:concurrent_hammer))
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 5_000))

      [row] = Bus.classes()
      assert row.occurrences == workers * per_worker
    end
  end
end
