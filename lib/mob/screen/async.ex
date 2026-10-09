defmodule Mob.Screen.Async do
  @moduledoc false

  # The process protocol behind `Mob.Socket.start_async/3`. Shared by
  # `Mob.Screen.Server` and `Mob.ScreenCase` so the off-device harness runs the
  # same message handling a device does.
  #
  # Each task is two processes. The *runner* is linked to the screen, traps
  # exits, and does nothing but report; the *worker*, linked to the runner, runs
  # the user's function. That split is what lets every way a worker can end be
  # reported as a message — a raise, a throw, an exit, and also an exit signal
  # from a process the function linked to (a crashing inner `Task.async/1`),
  # which a single linked process cannot catch and would pass on to the screen.
  # Under `Mob.ScreenCase` the screen is the test process, which does not trap
  # exits, so that signal would kill the test. And because the runner traps
  # exits, the screen's own exit — for any reason, `:normal` included — reaches
  # it as a message and it kills the worker.
  #
  # The screen monitors the runner. Each running task is stored under
  # `__mob__.async` as `name => %{pid, monitor, token}` (`pid` is the runner),
  # and every message this module consumes is matched against those entries. A
  # message for a token no longer stored (replaced, cancelled, already
  # delivered) is dropped, which is what makes the newest `start_async/3` for a
  # name the only one that reports.

  @type outcome :: {:ok, term()} | {:exit, term()}
  @type result ::
          :unknown
          | {:dropped, Mob.Socket.t()}
          | {:deliver, term(), outcome(), Mob.Socket.t()}

  @spec start(Mob.Socket.t(), term(), (-> term())) :: Mob.Socket.t()
  def start(%Mob.Socket{} = socket, name, fun) when is_function(fun, 0) do
    ensure_handle_async!(socket.__mob__.screen)

    socket = discard(socket, name)
    owner = self()
    token = make_ref()
    {:ok, pid} = Task.start_link(fn -> run(owner, token, fun) end)
    monitor = Process.monitor(pid)

    put_entry(socket, name, %{pid: pid, monitor: monitor, token: token})
  end

  @spec cancel(Mob.Socket.t(), term(), term()) :: Mob.Socket.t()
  def cancel(%Mob.Socket{} = socket, name, reason) do
    if reason == :normal do
      # A :normal exit signal is ignored by the process it is sent to, so the
      # task would keep running while handle_async reported it cancelled.
      raise ArgumentError, "cancel_async/3 cannot cancel with reason :normal"
    end

    case entries(socket) do
      %{^name => entry} ->
        stop(entry, reason)
        # Cancelling is decided here, not by the task's exit: the caller has
        # been told the work is cancelled, so a result must not follow. The
        # runner may still send one after stop/2 returns — Process.exit/2 is
        # asynchronous — so the entry moves to a new token, which drops it.
        token = make_ref()
        send(self(), {__MODULE__, token, {:exit, reason}})
        put_entry(socket, name, %{entry | token: token})

      _ ->
        socket
    end
  end

  @spec handle_message(term(), Mob.Socket.t()) :: result()
  def handle_message({__MODULE__, token, outcome}, socket) do
    case Enum.find(entries(socket), fn {_name, entry} -> entry.token == token end) do
      {name, entry} ->
        forget(entry)
        {:deliver, name, outcome, delete(socket, name)}

      nil ->
        {:dropped, socket}
    end
  end

  # Only a runner killed from outside ends without reporting first.
  def handle_message({:DOWN, monitor, :process, _pid, reason}, socket) do
    case Enum.find(entries(socket), fn {_name, entry} -> entry.monitor == monitor end) do
      {name, entry} ->
        forget(entry)
        {:deliver, name, {:exit, reason}, delete(socket, name)}

      nil ->
        :unknown
    end
  end

  # A killed runner's :DOWN follows and reports it; delivering this too would
  # report it twice.
  def handle_message({:EXIT, pid, _reason}, socket) do
    if Enum.any?(entries(socket), fn {_name, entry} -> entry.pid == pid end),
      do: {:dropped, socket},
      else: :unknown
  end

  def handle_message(_message, _socket), do: :unknown

  # Wait for the next message about one of this socket's tasks, in the calling
  # process. For Mob.ScreenCase, whose screen runs in the test process with no
  # GenServer to receive messages for it. Matches this socket's tasks only:
  # every view in a test reports to the same process, and consuming another
  # view's result here would drop it.
  @spec await(Mob.Socket.t(), timeout()) :: result() | :timeout
  def await(socket, timeout) do
    tokens = index(socket, :token)
    monitors = index(socket, :monitor)
    pids = index(socket, :pid)

    receive do
      {__MODULE__, token, _outcome} = message when is_map_key(tokens, token) ->
        handle_message(message, socket)

      {:DOWN, monitor, :process, _pid, _reason} = message when is_map_key(monitors, monitor) ->
        handle_message(message, socket)

      {:EXIT, pid, _reason} = message when is_map_key(pids, pid) ->
        handle_message(message, socket)
    after
      timeout -> :timeout
    end
  end

  @spec pending?(Mob.Socket.t()) :: boolean()
  def pending?(socket), do: entries(socket) != %{}

  defp run(owner, token, fun) do
    Process.flag(:trap_exit, true)

    # A :normal exit by the screen before the line above was ignored rather
    # than queued, and the worker would run on with nobody to report to.
    unless Process.alive?(owner), do: exit(:normal)

    runner = self()
    {:ok, worker} = Task.start_link(fn -> send(runner, {:result, fun.()}) end)

    outcome =
      receive do
        {:result, value} ->
          {:ok, value}

        {:EXIT, ^worker, reason} ->
          {:exit, reason}

        # The screen exited, or cancelled or replaced this task. Nobody is
        # waiting for an answer.
        {:EXIT, ^owner, _reason} ->
          Process.exit(worker, :kill)
          :stop
      end

    if outcome != :stop, do: send(owner, {__MODULE__, token, outcome})
  end

  defp ensure_handle_async!(module) do
    unless is_atom(module) and Code.ensure_loaded?(module) and
             function_exported?(module, :handle_async, 3) do
      raise ArgumentError,
            "start_async/3 delivers its result to handle_async/3, which " <>
              "#{inspect(module)} does not define"
    end
  end

  # Replacing a running task: its result would race the new one's. Silent, so
  # this also swallows a cancel of the same name whose {:exit, _} is not yet
  # delivered.
  defp discard(socket, name) do
    case entries(socket) do
      %{^name => entry} ->
        # Through the runner, which kills the worker with :kill. Killing the
        # runner instead would leave the worker only a :killed link signal,
        # which a worker that traps exits survives.
        stop(entry, {:shutdown, :replaced})
        delete(socket, name)

      _ ->
        socket
    end
  end

  defp stop(entry, reason) do
    forget(entry)
    Process.exit(entry.pid, reason)
    flush_result(entry.token)
  end

  # After unlink/1 returns no exit signal from the runner can arrive, but one
  # may already be queued; the demonitor flush covers the :DOWN the same way.
  defp forget(%{pid: pid, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_result(token) do
    receive do
      {__MODULE__, ^token, _outcome} -> :ok
    after
      0 -> :ok
    end
  end

  defp entries(socket), do: Map.get(socket.__mob__, :async, %{})

  defp index(socket, key),
    do: Map.new(entries(socket), fn {_name, entry} -> {entry[key], true} end)

  defp put_entry(socket, name, entry),
    do: Mob.Socket.put_mob(socket, :async, Map.put(entries(socket), name, entry))

  defp delete(socket, name),
    do: Mob.Socket.put_mob(socket, :async, Map.delete(entries(socket), name))
end
