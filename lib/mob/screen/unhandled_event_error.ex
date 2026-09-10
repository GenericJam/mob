defmodule Mob.Screen.UnhandledEventError do
  @moduledoc """
  Raised by the `handle_event/3` `use Mob.Screen` injects when a screen defines
  no clause for an event.

  A distinct exception rather than a `RuntimeError` with a recognisable message,
  because `Mob.Agent.Receipt` has to tell "this event matched nothing" apart
  from "the handler crashed" in order to attribute the first to event routing
  and the second to application code. Matching on message text would break the
  moment the wording changed.
  """

  defexception [:event, :screen]

  @impl Exception
  def message(%__MODULE__{event: event, screen: screen}) do
    "unhandled event #{inspect(event)} in #{inspect(screen)}. " <>
      "Add a handle_event/3 clause to handle it."
  end
end
