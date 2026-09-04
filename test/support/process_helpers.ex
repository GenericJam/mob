defmodule Mob.Test.ProcessHelpers do
  @moduledoc """
  Stopping a named process from test setup, without the race.

  The idiom this replaces appeared in nine test files:

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
        try do
          GenServer.stop(pid, :normal, timeout)
        catch
          # :noproc — it exited between the whereis and here, which is the race.
          # :normal / :shutdown — it was already on its way down.
          :exit, _ -> :ok
        end

        :ok
    end
  end
end
