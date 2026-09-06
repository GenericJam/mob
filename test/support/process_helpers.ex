defmodule Mob.Test.ProcessHelpers do
  @moduledoc """
  Stopping a named process from test setup, without the race.

  The idiom this replaces appeared six times across five test modules:

      case Process.whereis(Name) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

  That is check-then-act across a process boundary. `whereis` returns a live
  pid, the process exits before `stop` reaches it — a previous test's `on_exit`
  still draining, a supervisor restarting it, a linked owner going down — and
  `GenServer.stop/3` exits with `:noproc`, failing whichever test happened to
  run next.

  It failed exactly once in CI on `Mob.StateTest`, in setup, on a test that has
  nothing to do with what was being changed. That is the shape of this bug: it
  moves, it is rare, and it lands on whoever pushed last.
  """

  @doc """
  Stop `name` if it is running, tolerating it having already stopped.

  Returns `:ok` either way. Any exit reason is accepted, because a process that
  is already gone is the state the caller wanted.
  """
  @spec stop_if_running(GenServer.name(), timeout()) :: :ok
  def stop_if_running(name, timeout \\ 5_000) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        stop_pid(pid, timeout)
    end
  end

  @doc """
  Stop `pid` if it is running, tolerating it having already stopped.

  The pid-shaped version of the same race, which appeared 19 times across
  11 modules as:

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

  `Process.alive?/1` is a check-then-act just as `whereis` is. Since MOB-112
  the screen owner is *linked to the test process*, and ExUnit exits that
  process with `:shutdown` when the test ends — so the owner is dying
  concurrently with the very callback trying to stop it. The window is
  microseconds wide and CI is where it lands (MOB-123).

  Thirteen test modules had each written this correctly in private, byte for byte
  identically, which is a fair signal it belongs here instead.
  """
  @spec stop_pid(pid(), timeout()) :: :ok
  def stop_pid(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.stop(pid, :normal, timeout)
    :ok
  catch
    # Only one exit reason means "did not work": the process ignored a :normal
    # stop and is still alive, about to leak into the next test. That is the
    # failure this module exists to prevent, so it is the one thing that must
    # not be swallowed. `GenServer.stop/3` reports it as
    # `{:timeout, {GenServer, :stop, _}}`, not a bare atom.
    :exit, {:timeout, _} ->
      raise "#{inspect(pid)} ignored a :normal stop for #{timeout}ms and is still alive"

    # Everything else means it was already on its way down, which is the state
    # the caller wanted. Do not enumerate those shapes: they nest to varying
    # depths depending on how far into shutdown the process got — a linked
    # owner dying as ExUnit tears the test down arrives as
    # `{{:shutdown, {:sys, :terminate, _}}, {GenServer, :stop, _}}`. An earlier
    # version of this clause listed `{reason, _} when reason in [:normal,
    # :shutdown]` and failed on exactly that, in three tests, only under a full
    # concurrent run.
    :exit, _ ->
      :ok
  end

  @doc """
  Block until `pid` has actually exited, or fail loudly.

  Replaces the shape MOB-154 was opened for:

      Process.exit(pid, :kill)
      Process.sleep(10)
      # ... assert something that requires the process to be gone

  A fixed sleep is a bet on the scheduler. It wins on an idle laptop and loses
  on a loaded CI box, so the failure lands on whoever pushed next and looks
  unrelated to their change. A monitor is not a tighter bet — the `:DOWN`
  cannot arrive before the process is gone, so there is nothing left to race.

  Raises rather than returning on timeout: a test that continues after this
  fails is asserting against a process that may still be alive, which is the
  situation being avoided.
  """
  @spec await_exit(pid(), timeout()) :: :ok
  def await_exit(pid, timeout \\ 1_000) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        raise "#{inspect(pid)} was still alive after #{timeout}ms"
    end
  end

  @doc """
  Poll `fun` until it returns a truthy value, or fail after `timeout` ms.

  For the narrow case where a process mutates its own state in response to a
  message from *somewhere else* — a `:DOWN` from a monitor, say. A `call` from
  the test process is an ordering barrier only for messages the test itself
  sent; it says nothing about a `:DOWN` that arrived from a third party.

  Prefer a ready-message or a monitor when the thing you are waiting for is
  observable. Reach for this only when it genuinely is not: unlike a fixed
  sleep it returns as soon as the condition holds, and it reports the failure
  instead of letting the next assertion produce a confusing one.
  """
  @spec eventually((-> any()), non_neg_integer()) :: :ok
  def eventually(fun, timeout \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, timeout)
  end

  defp do_eventually(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "condition still false after #{timeout}ms"

      true ->
        Process.sleep(5)
        do_eventually(fun, deadline, timeout)
    end
  end

  @doc """
  Make sure `Mob.ComponentRegistry` is running, without any test owning it.

  The registry is globally named and owns a named ETS table, and two
  `async: true` modules use it. Under `start_supervised/1` whichever test won
  the race OWNED it, and ExUnit tore it — and its table — down at that test's
  end while the other module was still running (MOB-119).

  `test_helper.exs` starts it for the run, which fixes that for one `mix test`.
  It is not enough on its own: several sync modules deliberately stop it in
  teardown and do not restart it, and `--repeat-until-failure` loops inside
  `ExUnit.run/0` without re-running `test_helper.exs` — so on the second
  iteration the async setups would find it absent and own it again, restoring
  the exact race.

  Starting it here, unlinked and unsupervised, means no test can ever own it.
  """
  @spec ensure_component_registry() :: :ok
  def ensure_component_registry do
    case GenServer.start(Mob.ComponentRegistry, [], name: Mob.ComponentRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
