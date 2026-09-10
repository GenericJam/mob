defmodule Mob.Test.ProcessHelpersTest do
  @moduledoc """
  The helpers exist to remove races from test setup and teardown, so they are
  worth testing: a helper that silently does nothing would hide the very
  failures it was written to prevent.
  """
  use ExUnit.Case, async: true

  alias Mob.Test.ProcessHelpers

  describe "await_exit/2" do
    test "returns once the process is gone" do
      pid = spawn(fn -> :ok end)

      assert ProcessHelpers.await_exit(pid) == :ok
      refute Process.alive?(pid)
    end

    test "raises rather than continuing when the process outlives the timeout" do
      # The failure mode that matters. Returning quietly here would let the
      # caller assert against a process that is still running — exactly the
      # situation a fixed Process.sleep leaves you in, just with a nicer name.
      pid = spawn(fn -> Process.sleep(:infinity) end)

      assert_raise RuntimeError, ~r/still alive after/, fn ->
        ProcessHelpers.await_exit(pid, 20)
      end

      Process.exit(pid, :kill)
    end

    test "an already-dead process returns immediately" do
      pid = spawn(fn -> :ok end)
      :ok = ProcessHelpers.await_exit(pid)

      # Monitoring a dead pid delivers :DOWN straight away rather than hanging.
      assert ProcessHelpers.await_exit(pid) == :ok
    end
  end

  describe "stop_pid/2" do
    test "stops a live process" do
      {:ok, pid} = Agent.start(fn -> :state end)

      assert ProcessHelpers.stop_pid(pid) == :ok
      refute Process.alive?(pid)
    end

    test "tolerates a process that is already gone — the race it exists for" do
      {:ok, pid} = Agent.start(fn -> :state end)
      :ok = ProcessHelpers.stop_pid(pid)

      assert ProcessHelpers.stop_pid(pid) == :ok
    end

    test "raises when the process ignores a :normal stop" do
      # :timeout is the opposite of "already gone" — the process is alive and
      # about to leak into the next test. Returning :ok here would hide the
      # exact failure this module exists to prevent.
      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          Process.sleep(:infinity)
        end)

      assert_raise RuntimeError, ~r/still alive/, fn ->
        ProcessHelpers.stop_pid(pid, 50)
      end

      Process.exit(pid, :kill)
    end
  end

  defmodule TerminateCrasher do
    @moduledoc false
    use GenServer
    def init(_), do: {:ok, %{}}
    def terminate(_reason, _state), do: raise("boom in terminate")
  end

  describe "stop_pid/2 and crashes during terminate" do
    test "a process that raises in terminate/2 is reported, not swallowed" do
      # Swallowing this was the pre-existing behaviour and it hides real bugs:
      # a screen whose terminate/2 fails to flush state looks like a clean stop.
      {:ok, pid} = GenServer.start(TerminateCrasher, [])

      assert_raise RuntimeError, "boom in terminate", fn ->
        ProcessHelpers.stop_pid(pid)
      end
    end
  end

  describe "stop_all/2" do
    test "stops every pid even when an earlier one refuses, then raises" do
      # The whole point. If stop_all bailed at the first failure, the survivors
      # would leak into the next file under their global names — the failure
      # this module exists to prevent.

      wedged =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          Process.sleep(:infinity)
        end)

      {:ok, a} = Agent.start(fn -> :a end)
      {:ok, b} = Agent.start(fn -> :b end)

      assert_raise RuntimeError, ~r/1 process\(es\) refused to stop/, fn ->
        ProcessHelpers.stop_all([wedged, a, b], 50)
      end

      refute Process.alive?(a), "a was after the wedged pid and must still be stopped"
      refute Process.alive?(b), "b was after the wedged pid and must still be stopped"

      Process.exit(wedged, :kill)
    end

    test "ignores non-pids so an unregistered name is not a special case" do
      {:ok, a} = Agent.start(fn -> :a end)
      assert ProcessHelpers.stop_all([nil, a, Process.whereis(:definitely_not_registered)]) == :ok
      refute Process.alive?(a)
    end
  end

  describe "eventually/2" do
    test "returns as soon as the condition holds, not after the full timeout" do
      # The point of the helper over a fixed sleep: it pays the actual latency,
      # not the worst case.
      {us, :ok} =
        :timer.tc(fn ->
          ProcessHelpers.eventually(fn -> true end, 5_000)
        end)

      assert us < 100_000, "returned in #{us}us; should not wait out the deadline"
    end

    test "waits for a condition that becomes true later" do
      ref = :counters.new(1, [])

      spawn(fn ->
        Process.sleep(20)
        :counters.add(ref, 1, 1)
      end)

      assert ProcessHelpers.eventually(fn -> :counters.get(ref, 1) > 0 end) == :ok
    end

    test "raises, naming the timeout, when the condition never holds" do
      # Without this, a helper that silently returned :ok would void every test
      # that uses it as its only assertion.
      assert_raise RuntimeError, ~r/still false after 50ms/, fn ->
        ProcessHelpers.eventually(fn -> false end, 50)
      end
    end

    test "treats nil and false as not-yet, anything else as satisfied" do
      assert ProcessHelpers.eventually(fn -> :some_value end, 50) == :ok
      assert_raise RuntimeError, fn -> ProcessHelpers.eventually(fn -> nil end, 50) end
    end

    test "lets an exception from the condition through instead of polling on it" do
      # A condition that raises is a broken test, not a not-yet. Retrying it
      # would turn a clear error into "condition still false after 1000ms".
      assert_raise ArgumentError, fn ->
        ProcessHelpers.eventually(fn -> raise ArgumentError end, 50)
      end
    end

    test "lets an exit from the condition through" do
      # e.g. calling a GenServer that has died: the :noproc should surface as
      # itself, not be swallowed by the deadline.
      assert catch_exit(ProcessHelpers.eventually(fn -> exit(:noproc) end, 50)) == :noproc
    end
  end

  describe "stop_if_running/2" do
    test "stops a named process and tolerates its absence" do
      # Unique per run, not a fixed atom. A test that documents the danger of
      # shared global names should not register one: if this failed before its
      # cleanup, the agent would outlive the run and break the next repeat.
      name = :"helpers_probe_#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.start(fn -> :state end, name: name)

      assert ProcessHelpers.stop_if_running(name) == :ok
      assert ProcessHelpers.stop_if_running(name) == :ok
    end
  end
end
