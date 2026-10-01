defmodule Mob.Event.NativeInput do
  @moduledoc """
  Which messages are native input, and what each one is called outside the
  screen it was meant for.

  Native input never goes through `Mob.Event.dispatch/4`. The NIF delivers the
  legacy tuples listed in `Mob.Listener` — `{:tap, tag}`, `{:change, tag,
  value}`, `{event, tag}`, `{event, tag, payload}` — and the listener forwards
  them to the screen as they are. So the two things that observe actions,
  `Mob.Agent.Receipts` and `Mob.Event.Trace`, have to recognise them where they
  land: in `Mob.Screen.Server`, and in `Mob.Listener` when the screen is gone.
  This module is the one place that says which tuples those are.

  ## Discrete and stream

  | Kind | Messages | Receipt | Trace |
  |---|---|---|---|
  | `:discrete` | `:tap` (list-row select included), `:focus`, `:blur`, `:submit`, `:select`, `:dismiss`, `:long_press`, `:double_tap`, `:swipe_left`/`_right`/`_up`/`_down`, `{:swipe, tag, direction}`, `{:change, tag, value}` except a float | yes | yes |
  | `:stream` | `:scroll`, `:drag`, `:pinch`, `:rotate`, `:pointer_move`, `:compose`, a float `:change`, and the scroll lifecycle (`:scroll_began`, `:scroll_ended`, `:scroll_settled`, `:top_reached`, `:scrolled_past`) | no | yes |

  A stream fires at up to display rate, or several times per gesture. The
  receipt store keeps 256, so one scroll would evict the tap an agent is about
  to ask about, and a receipt costs an assigns comparison and an ETS write per
  frame. A float `:change` is a slider — the only native sender of a float
  value — which reports every step of a drag. Text, toggle and tab changes stay
  discrete: one per keystroke or flip is the rate a person acts at.

  ## Naming

  An input is named by its canonical address and event atom, from
  `Mob.Event.Bridge.legacy_to_canonical/3` where the Bridge models the shape.
  Where it does not, the same rule applies with the widget kind the event
  implies (`:text_field` for focus, blur and submit, `:sheet` for dismiss,
  `:button` otherwise, as for a tap). A `:change` takes its widget from the
  value's type, which is all native tells us about the control: a boolean is a
  `:toggle`, a binary a `:text_field` (anything else keeps the Bridge's
  default). A tag that is not a valid address id
  (`Mob.Event.Address.validate_id/1`) is named `:opaque`.

  A receipt carries the name and never the payload: a text field's value is
  user data, and a receipt is written to ETS and handed to telemetry. A trace
  carries the payload, as `Mob.Event.dispatch/4` always has — subscribing is an
  explicit debugging act.
  """

  alias Mob.Event.{Address, Bridge}

  @type kind :: :discrete | :stream | :none

  @discrete [
    :tap,
    :focus,
    :blur,
    :submit,
    :select,
    :dismiss,
    :long_press,
    :double_tap,
    :swipe_left,
    :swipe_right,
    :swipe_up,
    :swipe_down
  ]
  @discrete_with_payload [:change, :swipe]
  @stream [:scroll_began, :scroll_ended, :scroll_settled, :top_reached, :scrolled_past]
  @stream_with_payload [:scroll, :drag, :pinch, :rotate, :pointer_move, :compose]

  @doc "Whether `message` is discrete native input, a stream, or not native input."
  @spec kind(term()) :: kind()
  def kind({:change, _tag, value}) when is_float(value), do: :stream
  def kind({event, _tag}) when event in @discrete, do: :discrete
  def kind({event, _tag, _payload}) when event in @discrete_with_payload, do: :discrete
  def kind({event, _tag}) when event in @stream, do: :stream
  def kind({event, _tag, _payload}) when event in @stream_with_payload, do: :stream
  def kind(_message), do: :none

  @doc """
  The canonical `{address, event, payload}` for a native input message, with
  `:opaque` in place of the address when the tag is not a valid id.
  """
  @spec canonical(tuple(), term()) :: {Address.t() | :opaque, atom(), term()}
  def canonical(message, screen) do
    case Bridge.legacy_to_canonical(message, screen, widget_opts(message)) do
      {:ok, {:mob_event, addr, event, payload}} -> {addr, event, payload}
      :passthrough -> unmodelled(message, screen)
    end
  end

  # The Bridge calls every `:change` a `:text_field`, which mislabels a toggle.
  # Only the value's type is read; a receipt still never carries the value.
  defp widget_opts({:change, _tag, value}) when is_boolean(value), do: [widget: :toggle]
  defp widget_opts({:change, _tag, value}) when is_binary(value), do: [widget: :text_field]
  defp widget_opts(_message), do: []

  @doc """
  What a receipt records for a native input: `{event, address}`, or
  `{event, :opaque}`. Never the payload.
  """
  @spec receipt_event(tuple(), term()) :: {atom(), Address.t() | :opaque}
  def receipt_event(message, screen) do
    {addr, event, _payload} = canonical(message, screen)
    {event, addr}
  end

  defp unmodelled({event, tag}, screen), do: unmodelled(event, tag, nil, screen)
  defp unmodelled({event, tag, payload}, screen), do: unmodelled(event, tag, payload, screen)

  defp unmodelled(event, tag, payload, screen) do
    case Address.validate_id(tag) do
      :ok -> {Address.new(screen: screen, widget: widget(event), id: tag), event, payload}
      {:error, _reason} -> {:opaque, event, payload}
    end
  end

  # Shapes the Bridge declines only for an invalid tag never reach here with a
  # valid one, so only events it does not model at all need a widget kind.
  defp widget(event) when event in [:focus, :blur, :submit, :compose], do: :text_field
  defp widget(:dismiss), do: :sheet
  defp widget(event) when event in @stream_with_payload, do: event
  defp widget(_event), do: :button
end
