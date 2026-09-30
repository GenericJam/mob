defmodule Mob.Event.Trace do
  @moduledoc """
  Live tracing of Mob events for IEx debugging.

  Subscribe a process to receive every event that flows through `Mob.Event`.
  Tracing is opt-in and costs one `:persistent_term` read per dispatch when no
  tracers are registered.

  ## Usage

      # In IEx connected to the running app:
      Mob.Event.Trace.subscribe()

      # Now every event delivered via Mob.Event.dispatch/4 also lands in your
      # mailbox tagged {:mob_trace, addr, event, payload}. Pattern-match it,
      # log it, whatever.

      flush()  # see what's in the mailbox

      # Filter on the way out:
      Mob.Event.Trace.subscribe(fn addr -> addr.widget == :list end)

      # From a shell on another node, name the pid to deliver to — `:rpc`
      # runs the call in a short-lived process that would receive nothing:
      :rpc.call(node, Mob.Event.Trace, :subscribe, [self(), nil])

      # Stop tracing:
      Mob.Event.Trace.unsubscribe()   # this process
      Mob.Event.Trace.stop()          # every tracer

  Tracers are monitored by `Mob.Diag.Subscribers`, so one that exits (or whose
  node disconnects) stops being traced to without an `unsubscribe/1`.

  ## Performance

  When no tracers are registered (the default), `Mob.Event.dispatch/4` reads an
  empty list from `:persistent_term` and returns. When tracers are registered,
  each one is `send`ed a copy of the envelope. Tracer filter functions run in the
  dispatch path, so keep them cheap.
  """

  alias Mob.Diag.Subscribers
  alias Mob.Event.Address

  @topic :event_trace

  @doc false
  @deprecated "Tracing needs no setup; subscribe/0, subscribe/1 or subscribe/2 is enough."
  @spec start() :: :ok
  def start, do: :ok

  @doc "Stop tracing: unsubscribe every tracer."
  @spec stop() :: :ok
  def stop, do: Subscribers.clear(@topic)

  @doc """
  Subscribe the current process to receive trace messages.

  If `filter` is provided, only events for which `filter.(addr)` returns
  truthy are delivered to this subscriber.

  Messages arrive shaped `{:mob_trace, addr, event, payload}`.
  """
  @spec subscribe((Address.t() -> boolean()) | nil) :: :ok
  def subscribe(filter \\ nil), do: subscribe(self(), filter)

  @doc """
  Subscribe `pid` — which may be on another node — with an optional `filter`.
  Subscribing a pid again replaces its filter.
  """
  @spec subscribe(pid(), (Address.t() -> boolean()) | nil) :: :ok
  def subscribe(pid, filter) when is_pid(pid) and (is_nil(filter) or is_function(filter, 1)) do
    {:ok, _ref} = Subscribers.subscribe(@topic, pid, filter)
    :ok
  end

  @doc "Unsubscribe `pid` (defaults to the current process)."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()), do: Subscribers.unsubscribe(@topic, pid)

  @doc """
  Called by `Mob.Event.dispatch/4` to deliver to all tracers. Internal API.

  Never raises: it runs inside the dispatching screen, and a tracer is a
  debugging aid that must not change what it observes.
  """
  @spec broadcast(Address.t(), atom(), term()) :: :ok
  def broadcast(%Address{} = addr, event, payload) when is_atom(event) do
    for {pid, filter} <- Subscribers.list(@topic), matches?(filter, addr) do
      deliver(pid, {:mob_trace, addr, event, payload})
    end

    :ok
  end

  # `send/2` to a remote pid encodes the term in this process and raises if it
  # cannot; the event must still reach the screen and every other tracer.
  defp deliver(pid, message) do
    send(pid, message)
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _kind, _reason -> :ok
  end

  defp matches?(nil, _addr), do: true

  # A filter that raises, throws or exits is a non-match, never a crash of the
  # screen that is dispatching.
  defp matches?(filter, addr) when is_function(filter, 1) do
    !!filter.(addr)
  catch
    # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
    _kind, _reason -> false
  end
end
