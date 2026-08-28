defmodule Mob.Listener do
  @moduledoc """
  The single process the native layer delivers interaction events to.

  Native knows two things and neither of them is a screen: the registered name
  `:mob_screen` (used by `enif_whereis_pid` for the back gesture, alert actions
  and the launch-notification fallback, on both platforms) and whatever pid was
  stored in a tap handle by `register_tap/1`. This module takes over the second.

  ## The envelope

  `nif_register_tap` stores an arbitrary term as the handle's tag and echoes it
  back verbatim — `mob_send_tap` sends `{:tap, tag}`, `mob_send_event` sends
  `{event, tag}`. The tag is copied with `enif_make_copy`, so it can be any
  shape, including a nested tuple.

  So instead of registering `{screen_pid, tag}`, `Mob.Renderer` registers

      {listener_pid, {:mob_route, screen_pid, tag}}

  Native then delivers `{:tap, {:mob_route, screen_pid, tag}}` here, and the
  listener forwards `{:tap, tag}` to the screen. Native remains ignorant that
  screens exist, and **no `.m`, `.zig` or generator-template change is
  required** to move the inbound path off a single hard-wired screen process.

  Native has **two** message shapes for handle-addressed events, and the
  listener has to unwrap both:

  * `{event, tag}` — `mob_send_tap`, `mob_send_event`, `mob_send_scrolled_past`.
    Covers `:tap`, `:focus`, `:blur`, `:submit`, `:dismiss`, `:select` and the
    other payload-free events.
  * `{event, tag, payload}` — `mob_send_change`, `mob_send_compose`,
    `mob_send_swipe_with_direction`, `mob_send_scroll`, `mob_send_drag`,
    `mob_send_pinch`, `mob_send_rotate`, `mob_send_pointer_move`. This is
    everything carrying a value: text-field and toggle and slider `on_change`,
    tab selection, and every gesture stream.

  Both are unwrapped on the event atom rather than one clause per event, so a
  new event kind needs no change here — but a new *arity* would. Anything else
  is logged rather than silently discarded, because an unmodelled shape is
  invisible otherwise: the widget simply stops working.

  ## Why a hop at all

  Today there is one screen process, so carrying its pid through the envelope
  and forwarding is, on its own, a hop that buys nothing. What it buys is that
  the ~35 `register_tap` call sites in `Mob.Renderer` stop naming a screen
  process directly. When MOB-112 makes screens processes and MOB-113 adds the
  router, the change is confined to `handler/1` and `handle_info/2` here rather
  than spread across every interactive prop in the renderer.

  ## The escape hatch

  A high-frequency stream — drag, scroll, `mob_touch` at display rate — pays one
  extra hop and one extra copy per event. Registering the screen pid directly
  bypasses this module entirely and still works, because that is exactly what
  the renderer did before:

      nif.register_tap({screen_pid, tag})   # direct, no listener

  Nothing bypasses it today. The hop has not been measured, and adding an
  exception before there is a number to point at would be guessing.
  """

  use GenServer

  require Logger

  @doc "Start the listener. Named, so there is exactly one."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the listener is running."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Start the listener if it is not already running.

  Unlinked, for the same reason `Mob.Sender.ensure_started/0` is: the caller is
  usually a screen, and a screen crash must not take down the process every
  screen's events arrive through.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    if running?() do
      :ok
    else
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  @doc """
  Wrap a `register_tap/1` target so native delivers the event here instead of
  straight to the screen.

  Accepts either shape the renderer uses — a bare pid, or `{pid, tag}` — and
  returns the term to hand to `register_tap/1`.

  Returns the target **unchanged** when the listener is not running, so events
  go directly to the screen exactly as they did before this module existed.
  That is the fallback for any boot path that does not start a listener, and it
  is what keeps the renderer's own tests working without one.
  """
  @spec handler(pid() | {pid(), term()}) :: pid() | {pid(), term()}
  def handler(target) do
    case {Process.whereis(__MODULE__), envelope(target)} do
      {nil, _} -> target
      {_listener, ^target} -> target
      {listener, envelope} -> {listener, envelope}
    end
  end

  # A bare pid registers with no tag; native substitutes the atom :ok and the
  # screen receives {:tap, :ok}. Preserved exactly.
  defp envelope(pid) when is_pid(pid), do: {:mob_route, pid, :ok}
  defp envelope({pid, tag}) when is_pid(pid), do: {:mob_route, pid, tag}
  # Anything else passes through untouched, matching what the no-listener
  # branch does. The two branches disagreeing would mean a shape that works
  # without a listener and raises mid-render with one.
  defp envelope(other), do: other

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_info({event, {:mob_route, pid, tag}}, state) when is_atom(event) do
    # Sending to a dead pid is a no-op in the BEAM, which is the behaviour we
    # want: a handle registered by a screen that has since been popped and
    # stopped drops its event rather than delivering it to whatever screen
    # happens to be current. That is the misrouting MOB-107 reported.
    send(pid, {event, tag})
    {:noreply, state}
  end

  def handle_info({event, {:mob_route, pid, tag}, payload}, state) when is_atom(event) do
    send(pid, {event, tag, payload})
    {:noreply, state}
  end

  def handle_info(message, state) do
    # An envelope shape we do not model reaches the screen as nothing at all —
    # the control just stops responding, with no crash and no log. Say so.
    if routed?(message) do
      Logger.error("[mob] Mob.Listener received an unhandled routed event: #{inspect(message)}")
    end

    {:noreply, state}
  end

  defp routed?(message) when is_tuple(message) do
    message
    |> Tuple.to_list()
    |> Enum.any?(&match?({:mob_route, _pid, _tag}, &1))
  end

  defp routed?(_message), do: false
end
