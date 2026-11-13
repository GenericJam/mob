defmodule Mob.Event.Touch do
  @moduledoc """
  The `on_touch` contract: per-node, per-pointer touch streams (MOB-518).

      box(on_touch: {self(), :pad})                       # down, up, cancel
      box(on_touch: {self(), :pad, moves: true})          # plus moves, 16 ms / 1 dp
      box(on_touch: {self(), :pad, moves: true, throttle: 0, delta: 0})

  Every event arrives as `{:touch, tag, payload}`:

      def handle_info({:touch, :pad, %{phase: :down, y: y, height: h}}, socket) do
        velocity = round(127 * (1 - 0.85 * y / h))
        ...
      end

  A pointer belongs to the node it went down on until it lifts: a finger that
  slides onto another `on_touch` node sends that node nothing. Every `:down`
  is followed by exactly one `:up` or `:cancel` with the same `pointer_id`,
  however many renders happen in between. Moves are off unless `moves: true`,
  and then sent per pointer when at least `throttle` ms have passed and the
  pointer has moved at least `delta` dp (summed x and y distance) since its
  last sent event. `on_touch` observes without consuming, so `on_tap`,
  `on_long_press`, `on_press_in` / `on_press_out` and scrolling on the same
  node keep working.

  See `guides/events.md` ("Touch") and
  `decisions/2026-11-12-per-node-multi-pointer-on-touch.md`.
  """

  @type phase :: :down | :move | :up | :cancel

  @typedoc """
  * `pointer_id` — the same from a pointer's down to its up or cancel, and
    different from every other pointer down at the same time. Not
    necessarily small or zero-based.
  * `x`, `y` — dp from the node's top-left corner. Outside `0..width` /
    `0..height` once a pointer has left the node it went down on.
  * `width`, `height` — the node's size in dp when the event happened.
  * `ts` — milliseconds from the platform's monotonic input clock (Android
    `uptimeMillis`, iOS `UITouch.timestamp`). Only differences mean anything.
  """
  @type payload :: %{
          phase: phase(),
          pointer_id: integer(),
          x: float(),
          y: float(),
          width: float(),
          height: float(),
          ts: integer()
        }

  @type config :: %{moves: boolean(), throttle_ms: non_neg_integer(), delta: number()}

  @phases [:down, :move, :up, :cancel]
  @default_throttle_ms 16
  @default_delta 1.0

  @doc """
  Parse the options of `on_touch: {pid, tag, opts}`.

      iex> Mob.Event.Touch.parse_opts([])
      %{moves: false, throttle_ms: 16, delta: 1.0}

      iex> Mob.Event.Touch.parse_opts(moves: true, throttle: 0, delta: 0)
      %{moves: true, throttle_ms: 0, delta: 0}

  `throttle:` and `delta:` tune moves, so either one without `moves: true`
  raises rather than doing nothing. Unknown options raise too.
  """
  @spec parse_opts(keyword()) :: config()
  def parse_opts(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "on_touch options must be a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:moves, :throttle, :delta] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown on_touch option(s) #{inspect(unknown)}"
    end

    moves = Keyword.get(opts, :moves, false)
    throttle = Keyword.get(opts, :throttle, @default_throttle_ms)
    delta = Keyword.get(opts, :delta, @default_delta)

    unless is_boolean(moves) do
      raise ArgumentError, "on_touch moves: must be a boolean, got: #{inspect(moves)}"
    end

    unless is_integer(throttle) and throttle >= 0 do
      raise ArgumentError,
            "on_touch throttle: must be a non-negative integer (ms), got: #{inspect(throttle)}"
    end

    unless is_number(delta) and delta >= 0 do
      raise ArgumentError,
            "on_touch delta: must be a non-negative number (dp), got: #{inspect(delta)}"
    end

    if not moves and (Keyword.has_key?(opts, :throttle) or Keyword.has_key?(opts, :delta)) do
      raise ArgumentError,
            "on_touch throttle:/delta: only apply to moves; add moves: true " <>
              "(got #{inspect(opts)})"
    end

    %{moves: moves, throttle_ms: throttle, delta: delta}
  end

  @doc """
  The message a touch delivers, for driving a screen without a finger
  (`Mob.Test.touch/4`, `Mob.ScreenCase.render_touch/4`). `fields` overrides
  any of `pointer_id` (default 0), `x`, `y`, `width`, `height` (default 0.0)
  and `ts` (default: this node's monotonic clock, in ms). Numbers are
  converted to the types native sends.

      iex> Mob.Event.Touch.message(:pad, :down, y: 30, height: 120, ts: 5)
      {:touch, :pad, %{phase: :down, pointer_id: 0, x: 0.0, y: 30.0, width: 0.0, height: 120.0, ts: 5}}
  """
  @spec message(term(), phase(), keyword()) :: {:touch, term(), payload()}
  def message(tag, phase, fields \\ []) when phase in @phases and is_list(fields) do
    case Keyword.keys(fields) -- [:pointer_id, :x, :y, :width, :height, :ts] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown touch field(s) #{inspect(unknown)}"
    end

    payload = %{
      phase: phase,
      pointer_id: Keyword.get(fields, :pointer_id, 0),
      x: Keyword.get(fields, :x, 0) * 1.0,
      y: Keyword.get(fields, :y, 0) * 1.0,
      width: Keyword.get(fields, :width, 0) * 1.0,
      height: Keyword.get(fields, :height, 0) * 1.0,
      ts: Keyword.get_lazy(fields, :ts, fn -> System.monotonic_time(:millisecond) end)
    }

    {:touch, tag, payload}
  end
end
