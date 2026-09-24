defmodule Mob.Keyboard do
  @moduledoc """
  The on-screen keyboard. No permission required.

  A `:text_field` brings the keyboard up when tapped. It goes down again on
  the field's return key, when another field takes focus, when the field
  leaves the render tree, and on iOS via the "Done" button `MobTextField`
  adds to the keyboard toolbar. What none of those cover is the app's own
  idea of done — a Save button of its own, a tap on blank space, a value it
  has just committed. This is the call for that handler:

      def handle_info({:tap, :save}, socket) do
        {:noreply, socket |> Mob.Keyboard.dismiss() |> save()}
      end

  It matters most for `keyboard: "decimal"` and `"number"`: those iOS
  keyboards have no return key, so `on_submit` never fires for them and the
  toolbar button is the only built-in exit.

  Act in the handler that dismisses, not in the field's `on_blur`. When that
  handler also re-renders, the keyboard goes down and a new `value:` reaches
  the field, but the blur may not arrive: it fires natively after the new
  render has committed and carries the earlier render's handle, which is
  dropped as stale (observed on the iOS 26.5 simulator; the blur does arrive
  when nothing re-renders). The handler already knows the field lost focus.

  iOS resigns the first responder found in any visible window of a connected
  scene — the view the keyboard is up for. Android calls
  `MobBridge.dismissKeyboard()` (`InputMethodManager.hideSoftInputFromWindow`)
  when the generated bridge defines it; today's templates don't, so there the
  NIF returns `{:error, :not_loaded}` and `dismiss/1` is a no-op — the field
  keeps its keyboard and nothing else changes.
  """

  @doc """
  Take the keyboard down. Fire-and-forget; returns the socket unchanged so it
  chains inside a `handle_info` / `handle_event` return. Nothing focused is
  not an error.
  """
  @spec dismiss(Mob.Socket.t()) :: Mob.Socket.t()
  def dismiss(socket) do
    # Guarded, unlike Mob.Haptic: this sits in handlers Mob.ScreenCase drives
    # on the host, where no NIF library loads and the stub raises — a screen
    # that chains it has to stay testable there.
    if function_exported?(:mob_nif, :dismiss_keyboard, 0), do: :mob_nif.dismiss_keyboard()
    socket
  end
end
