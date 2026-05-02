defmodule Mob.Event.Throttle do
  @moduledoc """
  Throttle / debounce config for high-frequency event subscriptions.

  See `guides/event_model.md` and `PLAN.md` Batch 5.

  ## Forms accepted

      on_scroll: {pid, tag}                        # default: 30 Hz throttle
      on_scroll: {pid, tag, throttle: 100}         # 10 Hz
      on_scroll: {pid, tag, throttle: 0}           # raw firing rate (no throttle)
      on_scroll: {pid, tag, debounce: 200}         # only after 200 ms of stillness
      on_scroll: {pid, tag, throttle: 50, delta: 4} # 20 Hz + 4 px delta threshold

  Defaults differ by event type:

  | Event | Default throttle | Default delta |
  |---|---|---|
  | `:scroll` | 30 Hz (33 ms) | 1 px |
  | `:drag` | 60 Hz (16 ms) | 1 px |
  | `:pinch` | 60 Hz (16 ms) | 0.01 (1%) |
  | `:rotate` | 60 Hz (16 ms) | 1° |
  | `:pointer_move` | 30 Hz (33 ms) | 4 px |

  ## Resulting native config

  Parsed config is passed across the NIF boundary as a small map (or atom for
  the default). The native side stores this per registered handle and
  enforces it before any `enif_send` is issued.
  """

  @type event_kind :: :scroll | :drag | :pinch | :rotate | :pointer_move

  @type config :: %{
          throttle_ms: non_neg_integer(),
          debounce_ms: non_neg_integer(),
          delta_threshold: number(),
          leading: boolean(),
          trailing: boolean()
        }

  @defaults %{
    scroll: %{throttle_ms: 33, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true},
    drag: %{throttle_ms: 16, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true},
    pinch: %{
      throttle_ms: 16,
      debounce_ms: 0,
      delta_threshold: 0.01,
      leading: true,
      trailing: true
    },
    rotate: %{throttle_ms: 16, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true},
    pointer_move: %{
      throttle_ms: 33,
      debounce_ms: 0,
      delta_threshold: 4,
      leading: true,
      trailing: false
    }
  }

  @doc """
  Returns the default throttle config for an event kind.

      iex> Mob.Event.Throttle.default_for(:scroll)
      %{throttle_ms: 33, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true}

      iex> Mob.Event.Throttle.default_for(:pointer_move).throttle_ms
      33
  """
  @spec default_for(event_kind()) :: config()
  def default_for(kind) when is_map_key(@defaults, kind), do: @defaults[kind]

  @doc """
  Parse a user-supplied opts list into a normalised config.

  Always returns a complete config (defaults filled in). Validates that
  numeric fields are non-negative and the right types.

      iex> Mob.Event.Throttle.parse(:scroll, [])
      %{throttle_ms: 33, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true}

      iex> Mob.Event.Throttle.parse(:scroll, throttle: 100)
      %{throttle_ms: 100, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true}

      iex> Mob.Event.Throttle.parse(:scroll, throttle: 0)
      %{throttle_ms: 0, debounce_ms: 0, delta_threshold: 1, leading: true, trailing: true}

      iex> Mob.Event.Throttle.parse(:scroll, debounce: 200)
      %{throttle_ms: 33, debounce_ms: 200, delta_threshold: 1, leading: true, trailing: true}
  """
  @spec parse(event_kind(), keyword()) :: config()
  def parse(kind, opts) when is_atom(kind) and is_list(opts) do
    base = default_for(kind)

    base
    |> maybe_set(:throttle_ms, opts[:throttle])
    |> maybe_set(:debounce_ms, opts[:debounce])
    |> maybe_set(:delta_threshold, opts[:delta])
    |> maybe_set(:leading, opts[:leading])
    |> maybe_set(:trailing, opts[:trailing])
    |> validate!()
  end

  defp maybe_set(map, _key, nil), do: map
  defp maybe_set(map, key, value), do: Map.put(map, key, value)

  defp validate!(config) do
    if not is_integer(config.throttle_ms) or config.throttle_ms < 0 do
      raise ArgumentError,
            "throttle must be a non-negative integer (ms), got #{inspect(config.throttle_ms)}"
    end

    if not is_integer(config.debounce_ms) or config.debounce_ms < 0 do
      raise ArgumentError,
            "debounce must be a non-negative integer (ms), got #{inspect(config.debounce_ms)}"
    end

    if not is_number(config.delta_threshold) or config.delta_threshold < 0 do
      raise ArgumentError,
            "delta must be a non-negative number, got #{inspect(config.delta_threshold)}"
    end

    if not is_boolean(config.leading), do: raise(ArgumentError, "leading must be a boolean")
    if not is_boolean(config.trailing), do: raise(ArgumentError, "trailing must be a boolean")

    config
  end

  @doc """
  Returns true if the throttle config equals the defaults — used by the
  renderer to skip serialising trivial configs across the NIF boundary.
  """
  @spec default?(event_kind(), config()) :: boolean()
  def default?(kind, config), do: config == default_for(kind)
end
