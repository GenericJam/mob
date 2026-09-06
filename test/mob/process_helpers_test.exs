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
