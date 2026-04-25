defmodule Mob.Alert do
  @moduledoc """
  Native alert dialogs, action sheets, and toast messages.

  All functions return the socket unchanged so they can be pipelined.

  ## Alert

  Centered modal dialog for confirmations and errors. Maps to
  `UIAlertController(.alert)` on iOS and `AlertDialog` on Android.

      def handle_event("delete", _params, socket) do
        Mob.Alert.alert(socket,
          title: "Delete item?",
          message: "This cannot be undone.",
          buttons: [
            [label: "Delete", style: :destructive, action: :confirmed_delete],
            [label: "Cancel", style: :cancel]
          ]
        )
      end

      def handle_info({:alert, :confirmed_delete}, socket) do
        {:noreply, do_delete(socket)}
      end

  ## Action sheet

  Bottom-anchored list for choosing between actions. Maps to
  `UIAlertController(.actionSheet)` on iOS and a list dialog on Android.

      Mob.Alert.action_sheet(socket,
        title: "Share photo",
        buttons: [
          [label: "Save to Photos", action: :save],
          [label: "Copy link",      action: :copy],
          [label: "Cancel",         style: :cancel]
        ]
      )

  ## Toast

  Ephemeral status message. No button, no callback.

      Mob.Alert.toast(socket, "Saved!", duration: :short)

  iOS renders a floating label overlay (no native equivalent).
  Android uses `Toast`.

  ## Button options

  | Key | Values | Default |
  |-----|--------|---------|
  | `:label` | string | `""` |
  | `:style` | `:default`, `:cancel`, `:destructive` | `:default` |
  | `:action` | atom delivered as `{:alert, atom}` | `:dismiss` |

  Cancel-style buttons send `{:alert, :dismiss}` when tapped unless you
  specify a different `:action`.
  """

  @doc """
  Show a centered alert dialog.

  Result arrives as `{:alert, action_atom}` in `handle_info/2`.
  Dismissing the dialog without tapping a button (e.g. Android back gesture)
  sends `{:alert, :dismiss}`.
  """
  @spec alert(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def alert(socket, opts) do
    title = to_string(opts[:title] || "")
    message = to_string(opts[:message] || "")
    buttons = opts[:buttons] || [[label: "OK", style: :cancel]]
    :mob_nif.alert_show(title, message, encode_buttons(buttons))
    socket
  end

  @doc """
  Show a bottom-anchored action sheet.

  Result arrives as `{:alert, action_atom}` in `handle_info/2`.
  """
  @spec action_sheet(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def action_sheet(socket, opts) do
    title = to_string(opts[:title] || "")
    buttons = opts[:buttons] || []
    :mob_nif.action_sheet_show(title, encode_buttons(buttons))
    socket
  end

  @doc """
  Show a brief ephemeral toast message. No callback.

  Options:
    - `:duration` — `:short` (default, ~2 s) or `:long` (~4 s)
  """
  @spec toast(Mob.Socket.t(), String.t(), keyword()) :: Mob.Socket.t()
  def toast(socket, message, opts \\ []) do
    duration = if opts[:duration] == :long, do: "long", else: "short"
    :mob_nif.toast_show(to_string(message), duration)
    socket
  end

  @doc false
  def encode_buttons(buttons) do
    buttons
    |> Enum.map(fn btn ->
      %{
        "label" => to_string(btn[:label] || ""),
        "style" => to_string(btn[:style] || :default),
        "action" => to_string(btn[:action] || :dismiss)
      }
    end)
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end
