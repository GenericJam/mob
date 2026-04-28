defmodule Mob.Event.Trace do
  @moduledoc """
  Live tracing of Mob events for IEx debugging.

  Subscribe a process to receive every event that flows through `Mob.Event`.
  Uses ETS for the registry; tracing is opt-in and adds zero cost when no
  tracers are registered.

  ## Usage

      # In IEx connected to the running app:
      Mob.Event.Trace.start()
      Mob.Event.Trace.subscribe()

      # Now every event delivered via Mob.Event.dispatch/4 also lands in your
      # mailbox tagged {:mob_trace, addr, event, payload}. Pattern-match it,
      # log it, whatever.

      flush()  # see what's in the mailbox

      # Filter on the way out:
      Mob.Event.Trace.subscribe(fn addr -> addr.widget == :list end)

      # Stop tracing:
      Mob.Event.Trace.unsubscribe()
      Mob.Event.Trace.stop()

  ## Performance

  When no tracers are registered (the default), `Mob.Event.dispatch/4` does
  one ETS lookup: `:ets.whereis(:mob_event_trace)` returns `:undefined` and
  the trace branch is a no-op. Cost ~50ns per dispatch.

  When tracers are registered, each one is `send`ed a copy of the envelope.
  Tracer filter functions run in the dispatch path, so keep them cheap.
  """

  alias Mob.Event.Address

  @table :mob_event_trace

  @doc """
  Start the tracing table. Idempotent — safe to call multiple times.
  Call once at app startup if you want tracing always available.
  """
  @spec start() :: :ok
  def start do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Stop tracing and tear down the table.
  """
  @spec stop() :: :ok
  def stop do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end

    :ok
  end

  @doc """
  Subscribe the current process to receive trace messages.

  If `filter` is provided, only events for which `filter.(addr)` returns
  truthy are delivered to this subscriber.

  Messages arrive shaped `{:mob_trace, addr, event, payload}`.
  """
  @spec subscribe((Address.t() -> boolean()) | nil) :: :ok
  def subscribe(filter \\ nil) do
    start()
    :ets.insert(@table, {self(), filter})
    :ok
  end

  @doc "Unsubscribe the current process."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, self())
    end

    :ok
  end

  @doc """
  Called by `Mob.Event.dispatch/4` to deliver to all tracers. Internal API.

  Only iterates if the table exists (cheap miss when tracing is disabled).
  """
  @spec broadcast(Address.t(), atom(), term()) :: :ok
  def broadcast(%Address{} = addr, event, payload) when is_atom(event) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.foldl(
          fn {pid, filter}, _ ->
            if Process.alive?(pid) and matches?(filter, addr) do
              send(pid, {:mob_trace, addr, event, payload})
            else
              if not Process.alive?(pid), do: :ets.delete(@table, pid)
            end

            :ok
          end,
          :ok,
          @table
        )

        :ok
    end
  end

  defp matches?(nil, _addr), do: true

  defp matches?(filter, addr) when is_function(filter, 1) do
    try do
      !!filter.(addr)
    rescue
      _ -> false
    end
  end
end
