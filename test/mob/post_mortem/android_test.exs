defmodule Mob.PostMortem.AndroidTest do
  # async: false — Bus + Registry are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mob.Test.ProcessHelpers, only: [eventually: 1]

  alias Mob.Defect.Bus
  alias Mob.PostMortem.Android
  alias Mob.PostMortem.Journal
  alias Mob.PostMortem.Registry

  @moduletag :tmp_dir

  # Fake NIF used with sweep_with/2. Same shape as
  # Mob.PostMortem.IOSTest.FakeNIF but returns ApplicationExitInfo
  # entries.
  defmodule FakeNIF do
    def platform, do: Process.get(:test_platform, :host)
    def post_mortem_android_drain, do: Process.get(:test_entries, [])
  end

  setup %{tmp_dir: tmp_dir} do
    Bus.reset()
    Registry.reset()
    Journal.reset()
    on_exit(&Journal.reset/0)
    Bus.unsubscribe()
    {:ok, _ref} = Bus.subscribe()

    Process.put(:journal, Path.join(tmp_dir, "journal.etf"))
    Process.put(:test_platform, :android)
    Process.put(:test_entries, [])
    :ok
  end

  defp journal, do: Process.get(:journal)

  # What a new boot sees: a fresh bus and seen-set, and nothing pending in
  # memory. The journal file is all that carries over.
  defp reboot do
    Bus.reset()
    Registry.reset()
    Journal.reset()
    Process.put(:test_entries, [])
  end

  defp journaled_pids, do: for({:android, _id, e} <- Journal.read(journal()).entries, do: e.pid)

  # Reason codes from android.app.ApplicationExitInfo.
  @reason_signaled 2
  @reason_low_memory 3
  @reason_crash 4
  @reason_crash_native 5
  @reason_anr 6
  @reason_excessive_resource 9
  @reason_user_requested 10
  @reason_user_stopped 11
  @reason_dependency_died 12
  @reason_other 13

  defp entry(opts \\ []) do
    %{
      reason_code: Keyword.get(opts, :reason_code, @reason_anr),
      pid: Keyword.get(opts, :pid, 12_345),
      timestamp_ms: Keyword.get(opts, :timestamp_ms, 1_726_050_000_000),
      process_name: Keyword.get(opts, :process_name, "com.example.app"),
      description: Keyword.get(opts, :description, "Input dispatching timed out")
    }
  end

  describe "platform gating" do
    test "returns [] on iOS" do
      Process.put(:test_platform, :ios)
      Process.put(:test_entries, [entry()])
      assert Android.sweep_with(FakeNIF, journal()) == []
    end

    test "returns [] on host" do
      Process.put(:test_platform, :host)
      Process.put(:test_entries, [entry()])
      assert Android.sweep_with(FakeNIF, journal()) == []
    end

    test "returns [] on Android when the NIF is not loaded (default sweep/0)" do
      # `:mob_nif.platform/0` raises `:undef` in the host test suite;
      # safe_platform falls through to :host and sweep returns [].
      assert Android.sweep() == []
    end
  end

  describe "on Android with entries" do
    test "one entry per reason produces one capsule with the mapped kind" do
      Process.put(:test_entries, [
        entry(reason_code: @reason_crash_native),
        entry(reason_code: @reason_crash),
        entry(reason_code: @reason_signaled),
        entry(reason_code: @reason_anr),
        entry(reason_code: @reason_low_memory),
        entry(reason_code: @reason_excessive_resource),
        entry(reason_code: @reason_user_requested),
        entry(reason_code: @reason_user_stopped),
        entry(reason_code: @reason_dependency_died),
        entry(reason_code: @reason_other)
      ])

      capsules = Android.sweep_with(FakeNIF, journal())
      assert Enum.count(capsules) == 10

      # Each reason maps to the right (kind, severity) pair per the
      # Mob.Defect.emit_appexit_reason/1 mapping table.
      kinds = Enum.map(capsules, & &1.kind)

      assert kinds == [
               :native_crash,
               :native_crash,
               :native_crash,
               :anr,
               :oom,
               :oom,
               :user_kill,
               :user_kill,
               :user_kill,
               :user_kill
             ]

      severities = Enum.map(capsules, & &1.severity)

      assert severities == [
               :fatal,
               :fatal,
               :fatal,
               :critical,
               :fatal,
               :fatal,
               :info,
               :info,
               :info,
               :info
             ]
    end

    test "each capsule reaches the subscribed test process" do
      Process.put(:test_entries, [entry(reason_code: @reason_anr)])
      [capsule] = Android.sweep_with(FakeNIF, journal())
      assert_receive {:mob_defect, ^capsule}, 500
    end

    test "fingerprints group by kind + process + reason across timestamps and pids" do
      # Two ANRs of the same class in the same process (different pids
      # — the process restarted — and different timestamps) group into
      # one triage row.
      Process.put(:test_entries, [
        entry(reason_code: @reason_anr, pid: 1, timestamp_ms: 1_000),
        entry(reason_code: @reason_anr, pid: 2, timestamp_ms: 2_000)
      ])

      [a, b] = Android.sweep_with(FakeNIF, journal())
      assert a.fingerprint == b.fingerprint
    end

    test "a different reason code or process name changes the fingerprint" do
      Process.put(:test_entries, [
        entry(reason_code: @reason_anr, process_name: "com.example.app"),
        entry(reason_code: @reason_crash, process_name: "com.example.app"),
        entry(reason_code: @reason_anr, process_name: "com.example.other")
      ])

      [a, b, c] = Android.sweep_with(FakeNIF, journal())
      refute a.fingerprint == b.fingerprint
      refute a.fingerprint == c.fingerprint
      refute b.fingerprint == c.fingerprint
    end

    test "evidence rides on the capsule" do
      Process.put(:test_entries, [
        entry(
          reason_code: @reason_anr,
          pid: 99,
          timestamp_ms: 12_345,
          process_name: "com.example.app",
          description: "Input dispatching timed out"
        )
      ])

      [capsule] = Android.sweep_with(FakeNIF, journal())
      assert capsule.evidence.reason_code == @reason_anr
      assert capsule.evidence.process_name == "com.example.app"
      assert capsule.evidence.description == "Input dispatching timed out"
      assert capsule.evidence.timestamp_ms == 12_345
      assert capsule.evidence.source == :application_exit_info
    end

    test "idempotent — same entry drained twice emits once" do
      # In production the NIF's persistent marker filters this out
      # across sweeps; but a same-session re-drain (a caller polling
      # in a loop) reaches the Registry, which dedups by artifact id.
      entries = [entry(reason_code: @reason_anr)]
      Process.put(:test_entries, entries)

      first = Android.sweep_with(FakeNIF, journal())
      second = Android.sweep_with(FakeNIF, journal())

      assert Enum.count(first) == 1
      assert second == []
    end
  end

  describe "malformed input" do
    test "a non-map entry is silently skipped" do
      Process.put(:test_entries, [:garbage, entry(), nil])
      capsules = Android.sweep_with(FakeNIF, journal())
      assert Enum.count(capsules) == 1
    end

    test "a partial-shape map is dropped without crashing the sweep" do
      Process.put(:test_entries, [
        %{reason_code: @reason_anr},
        entry(reason_code: @reason_anr, pid: 1, timestamp_ms: 1),
        %{pid: 99, timestamp_ms: 2},
        entry(reason_code: @reason_crash, pid: 2, timestamp_ms: 2)
      ])

      log = capture_log(fn -> Process.put(:__caps__, Android.sweep_with(FakeNIF, journal())) end)
      capsules = Process.get(:__caps__)

      assert Enum.count(capsules) == 2

      assert Enum.map(capsules, & &1.kind) == [:anr, :native_crash]
      assert log =~ "[warning]"
      assert log =~ "malformed ApplicationExitInfo"
    end
  end

  describe "until observed (MOB-303)" do
    setup do
      Bus.unsubscribe()
      :ok
    end

    test "an exit nobody observed is emitted again by the next boot's sweep" do
      Process.put(:test_entries, [entry()])
      [first] = Android.sweep_with(FakeNIF, journal())

      reboot()
      [again] = Android.sweep_with(FakeNIF, journal())

      assert again.fingerprint == first.fingerprint
      assert again.evidence == first.evidence
      assert Android.sweep_with(FakeNIF, journal()) == []
    end

    test "an exit delivered to a subscriber when emitted is cleared at once" do
      {:ok, _ref} = Bus.subscribe()
      Process.put(:test_entries, [entry()])
      [capsule] = Android.sweep_with(FakeNIF, journal())
      assert_receive {:mob_defect, ^capsule}
      assert Journal.read(journal()).entries == []

      reboot()
      assert Android.sweep_with(FakeNIF, journal()) == []
    end

    # A subscriber that was away when the exit was emitted (not yet subscribed,
    # or parked while its node was disconnected) and comes back has seen
    # nothing emitted before, whatever it receives next. Neither has a class
    # listing.
    test "a later subscriber, later deliveries and a class listing do not observe the exit" do
      Process.put(:test_entries, [entry(pid: 1, timestamp_ms: 1)])
      [_] = Android.sweep_with(FakeNIF, journal())

      Bus.classes()
      {:ok, _ref} = Bus.subscribe()
      unrelated = Mob.Defect.emit_appexit_reason(entry(pid: 999))
      assert_receive {:mob_defect, ^unrelated}
      Process.put(:test_entries, [entry(pid: 2, timestamp_ms: 2)])
      [later] = Android.sweep_with(FakeNIF, journal())
      assert_receive {:mob_defect, ^later}

      assert journaled_pids() == [1]

      reboot()
      Bus.unsubscribe()
      assert [again] = Android.sweep_with(FakeNIF, journal())
      assert again.evidence.timestamp_ms == 1
    end

    for {where, unrelated} <- [evicted_from_the_ring: 70, past_the_limit: 10] do
      test "a recent/1 that does not return the exit does not observe it (#{where})" do
        Process.put(:test_entries, [entry()])
        [capsule] = Android.sweep_with(FakeNIF, journal())
        for pid <- 1..unquote(unrelated), do: Mob.Defect.emit_appexit_reason(entry(pid: pid))

        refute capsule in Bus.recent(5)

        reboot()
        assert [_] = Android.sweep_with(FakeNIF, journal())
      end
    end

    test "a recent/1 that returns the exit clears it" do
      Process.put(:test_entries, [entry(pid: 1, timestamp_ms: 1), entry(pid: 2, timestamp_ms: 2)])
      [first, second] = Android.sweep_with(FakeNIF, journal())

      assert [^second] = Bus.recent(1)
      assert journaled_pids() == [1]

      assert first in Bus.recent()
      assert journaled_pids() == []

      reboot()
      assert Android.sweep_with(FakeNIF, journal()) == []
    end

    for {what, contents} <- [
          garbage: "not a journal",
          wrong_term: :erlang.term_to_binary({:mob_post_mortem_journal, 1, 0, [:not_an_entry]})
        ] do
      test "a corrupt journal (#{what}) is treated as empty and still emits fresh entries" do
        File.write!(journal(), unquote(contents))
        Process.put(:test_entries, [entry()])

        log = capture_log(fn -> Process.put(:caps, Android.sweep_with(FakeNIF, journal())) end)
        assert [_] = Process.get(:caps)
        assert log =~ "unreadable journal"
        assert [_] = journaled_pids()
      end

      test "a corrupt journal (#{what}) is repaired by the sweep that finds it, so it logs once" do
        File.write!(journal(), unquote(contents))

        log = capture_log(fn -> assert Android.sweep_with(FakeNIF, journal()) == [] end)
        assert log =~ "unreadable journal"

        reboot()
        log = capture_log(fn -> assert Android.sweep_with(FakeNIF, journal()) == [] end)
        refute log =~ "unreadable journal"
      end
    end

    test "a journal that cannot be read or written still lets the sweep emit" do
      file = Path.join(Path.dirname(journal()), "a_file")
      File.write!(file, "")
      Process.put(:journal, Path.join(file, "journal.etf"))
      Process.put(:test_entries, [entry()])

      log = capture_log(fn -> Process.put(:caps, Android.sweep_with(FakeNIF, journal())) end)
      assert [_] = Process.get(:caps)
      assert log =~ "could not write"
    end

    test "the journal keeps the newest 32 entries and counts what it dropped" do
      Process.put(:test_entries, for(pid <- 1..40, do: entry(pid: pid, timestamp_ms: pid)))
      assert Enum.count(Android.sweep_with(FakeNIF, journal())) == 40

      assert journaled_pids() == Enum.to_list(9..40)
      assert Journal.read(journal()).dropped == 8

      reboot()
      assert Enum.count(Android.sweep_with(FakeNIF, journal())) == 32
    end

    test "concurrent sweeps keep every entry they drained" do
      path = journal()

      # `Capsule.new/1` probes the NIF, and on the host every probe is a failed
      # load (slow, and noisy in the log). Build each capsule from one made up
      # front instead.
      template = Mob.Defect.appexit_capsule(entry())
      build = fn e -> %{template | id: "c#{e.pid}", fingerprint: "fp#{e.pid}"} end

      tasks =
        for pid <- 1..16 do
          Task.async(fn ->
            receive do: (:go -> :ok)
            fresh = [{"id#{pid}", entry(pid: pid, timestamp_ms: pid)}]
            Journal.sweep(fn -> path end, :android, fresh, build)
          end)
        end

      # Correctness only. The lock this replaced (`:global.trans`) also slept a
      # random 125 ms or more per retry, but a wall-clock bound on 16 fsynced
      # writes flakes on a shared disk (1.08 s observed); the owner process
      # has no backoff to measure.
      for t <- tasks, do: send(t.pid, :go)
      emitted = Task.await_many(tasks, 30_000)

      assert Enum.all?(emitted, &match?([_], &1))
      assert Enum.sort(journaled_pids()) == Enum.to_list(1..16)
    end

    test "an owner that dies mid-call fails neither its caller nor the next one" do
      Process.put(:test_entries, [entry(pid: 1, timestamp_ms: 1)])
      [_] = Android.sweep_with(FakeNIF, journal())
      owner = Process.whereis(Journal)
      path = journal()

      capture_log(fn ->
        :sys.suspend(owner)

        task =
          Task.async(fn ->
            Process.put(:test_platform, :android)
            Process.put(:test_entries, [entry(pid: 2, timestamp_ms: 2)])
            Android.sweep_with(FakeNIF, path)
          end)

        eventually(fn -> Process.info(owner, :message_queue_len) == {:message_queue_len, 1} end)
        Process.exit(owner, :kill)

        assert [capsule] = Task.await(task, 1_000)
        assert capsule.evidence.timestamp_ms == 2
      end)

      # Not wedged: the next sweep reaches the restarted owner and journals.
      Process.put(:test_entries, [entry(pid: 3, timestamp_ms: 3)])
      [_] = Android.sweep_with(FakeNIF, path)
      assert 3 in journaled_pids()
    end

    test "a stuck journal owner holds a recent/1 reader only briefly; the observation lands once it resumes" do
      Process.put(:test_entries, [entry(pid: 1, timestamp_ms: 1)])
      [_] = Android.sweep_with(FakeNIF, journal())
      owner = Process.whereis(Journal)
      :sys.suspend(owner)
      on_exit(fn -> if Process.alive?(owner), do: :sys.resume(owner) end)

      # The reader's observation call gives up long before the 5 s call
      # timeout the sweep uses; the bound leaves a wide margin either side.
      {micros, recent} = capture_log_result(fn -> :timer.tc(fn -> Bus.recent() end) end)

      assert [%{evidence: %{timestamp_ms: 1}}] = recent
      assert micros < 3_000_000
      assert 1 in journaled_pids()

      # The request was not withdrawn, and the reader did see the exit: the
      # owner clears it once it runs again.
      :sys.resume(owner)
      eventually(fn -> journaled_pids() == [] end)
    end
  end

  # `capture_log/1` runs `fun` in this process; pass its result out by message.
  defp capture_log_result(fun) do
    log = capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert log =~ "observed failed"
    assert_received {:result, result}
    result
  end
end
