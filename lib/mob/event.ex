defmodule Mob.Event do
  @moduledoc """
  The unified event emission API for Mob.

  See `guides/event_model.md` for the full event model.

  Two responsibilities:

  1. **Emit** — given an `%Address{}`, an event atom, and a payload, deliver
     the canonical envelope `{:mob_event, addr, event, payload}` to the right
     pid (resolving in-tree or external targets).

  2. **Match** — small helpers (`is_event?/1`, `match_address?/2`) for handler
     code that wants to filter incoming events by address fields.

  Events built here — custom components, `send_test/7`, anything that already
  has an address — go through `emit/5` or `dispatch/4`, which is where they are
  traced. Native input does **not**: the NIF delivers legacy tuples
  (`{:tap, tag}`, `{:change, tag, value}`, ...) through `Mob.Listener`
  straight to the screen. `Mob.Screen.Server` names those by canonical address
  when they arrive, traces them, and records a receipt for the discrete ones —
  see `Mob.Event.NativeInput`. Neither path is traced twice.
  """

  alias Mob.Event.{Address, Target}

  require Logger

  @typedoc "The shape of every event message delivered to a handler."
  @type envelope :: {:mob_event, Address.t(), atom(), term()}

  @doc """
  Resolve `target` and deliver the event.

  Best-effort delivery: if the target can't be resolved (dead pid, unknown
  registered name, component not in the ancestor chain), logs a debug
  message and drops the event.

  Returns `:ok` always. Errors from resolution are logged, not raised — losing
  one event from a stale handle should never crash the BEAM.
  """
  @spec emit(Address.t(), atom(), term(), Target.spec(), Target.render_scope()) :: :ok
  def emit(%Address{} = addr, event, payload, target, scope)
      when is_atom(event) do
    case Target.resolve(target, scope) do
      {:ok, pid} ->
        dispatch(pid, addr, event, payload)

      {:error, reason} ->
        Logger.debug(fn ->
          "[Mob.Event] dropping #{event} for #{Address.to_string(addr)}: #{inspect(reason)}"
        end)

        :ok
    end
  end

  @doc """
  Send the event to an already-resolved pid.

  Used when the renderer pre-resolved the target at registration time and
  passes the pid directly. Skips re-resolution.

  Also broadcasts to any `Mob.Event.Trace` subscribers (zero cost when no
  tracers are registered).
  """
  @spec dispatch(pid(), Address.t(), atom(), term()) :: :ok
  def dispatch(pid, %Address{} = addr, event, payload) when is_pid(pid) and is_atom(event) do
    send(pid, {:mob_event, addr, event, payload})
    Mob.Event.Trace.broadcast(addr, event, payload)
    :ok
  end

  @doc """
  True if `msg` matches the canonical event envelope shape.

      iex> Mob.Event.is_event?({:mob_event, %Mob.Event.Address{screen: S, widget: :x, id: :y}, :tap, nil})
      true

      iex> Mob.Event.is_event?({:tap, :something})
      false
  """
  @spec is_event?(term()) :: boolean()
  def is_event?({:mob_event, %Address{}, event, _payload}) when is_atom(event), do: true
  def is_event?(_), do: false

  @doc """
  True if `addr` matches all the given filters.

  Filters is a keyword list of address fields and the values they must equal.
  Useful for one-off matches in `handle_info/2` clauses where you don't want
  to write a full struct pattern.

      iex> addr = %Mob.Event.Address{screen: S, widget: :button, id: :save}
      iex> Mob.Event.match_address?(addr, widget: :button)
      true

      iex> addr = %Mob.Event.Address{screen: S, widget: :button, id: :save}
      iex> Mob.Event.match_address?(addr, widget: :button, id: :cancel)
      false
  """
  @spec match_address?(Address.t(), keyword()) :: boolean()
  def match_address?(%Address{} = addr, filters) when is_list(filters) do
    Enum.all?(filters, fn {k, v} -> Map.get(addr, k) == v end)
  end

  # ── Test helpers ──────────────────────────────────────────────────────────

  @doc """
  Synthesize an event delivery to `pid`. Useful for tests — bypasses the
  native side entirely.

      Mob.Event.send_test(self(), MyScreen, :button, :save, :tap, nil)
      assert_receive {:mob_event, %Address{id: :save}, :tap, nil}
  """
  @spec send_test(pid(), atom() | pid(), atom(), Address.id(), atom(), term(), keyword()) :: :ok
  def send_test(pid, screen, widget, id, event, payload \\ nil, opts \\ []) do
    addr =
      Address.new(
        Keyword.merge(
          [
            screen: screen,
            widget: widget,
            id: id
          ],
          opts
        )
      )

    dispatch(pid, addr, event, payload)
  end
end
