defmodule Mob.Event.Trace do
  @moduledoc """
  Live tracing of Mob events for IEx debugging.

  Subscribe a process to receive every event that reaches a handler: events
  delivered through `Mob.Event.dispatch/4`, and native input — taps, changes,
  gestures, scroll — which arrives at a screen as a legacy tuple and is traced
  by `Mob.Screen.Server` when the screen receives it (see
  `Mob.Event.NativeInput`). Tracing is opt-in and costs one `:persistent_term`
  read per event when no tracers are registered.

  ## Usage

      # In IEx connected to the running app:
      Mob.Event.Trace.subscribe()

      # Now every event lands in your mailbox too, tagged
      # {:mob_trace, addr, event, payload}. A native tap on `on_tap: {self(),
      # :save}` arrives as {:mob_trace, %Address{widget: :button, id: :save},
      # :tap, nil}. Pattern-match it, log it, whatever.

      flush()  # see what's in the mailbox

      # Filter on the way out:
      Mob.Event.Trace.subscribe(fn addr -> addr.widget == :list end)

      # From a shell on another node, name the pid to deliver to — `:rpc`
      # runs the call in a short-lived process that would receive nothing:
      :rpc.call(node, Mob.Event.Trace, :subscribe, [self(), nil])

      # Stop tracing:
      Mob.Event.Trace.unsubscribe()   # this process
      Mob.Event.Trace.stop()          # every tracer

  Tracers are monitored by `Mob.Diag.Subscribers`, so one that exits stops being
  traced to without an `unsubscribe/1`. One whose node disconnects is paused,
  filter kept, until that node reconnects.

  ## What is not traced

  Native input the screen never receives: an event for a screen that has
  died is dropped by `Mob.Listener` and recorded as an `:undeliverable`
  receipt instead. Arbitrary `handle_info/2` messages — timers, PubSub — are
  not events and are not traced. A native tag that is not a valid address id
  has no canonical address and is not traced either.

  ## Performance

  When no tracers are registered (the default), each event reads an empty list
  from `:persistent_term` and returns; native input is not even given an
  address. When tracers are registered, each one is `send`ed a copy of the
  envelope, payload included. Tracer filter functions run in the dispatching
  process, so keep them cheap.
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
    deliver_all(Subscribers.list(@topic), addr, event, payload)
  end

  @doc """
  Called by `Mob.Screen.Server` for a native input message it received.
  Internal API.

  The address is built only when someone is listening, so with no tracers
  this is the same empty-list read as `broadcast/3`. Never raises.
  """
  @spec broadcast_input(tuple(), module()) :: :ok
  def broadcast_input(message, screen) do
    case Subscribers.list(@topic) do
      [] ->
        :ok

      tracers ->
        case Mob.Event.NativeInput.canonical(message, screen) do
          {%Address{} = addr, event, payload} -> deliver_all(tracers, addr, event, payload)
          {:opaque, _event, _payload} -> :ok
        end
    end
  end

  defp deliver_all(tracers, addr, event, payload) do
    for {pid, filter} <- tracers, matches?(filter, addr) do
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
