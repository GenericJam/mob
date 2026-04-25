defmodule Mob.Clipboard do
  @moduledoc """
  System clipboard access. No permission required.

  ## Write

      def handle_event("copy", _params, socket) do
        Mob.Clipboard.put(socket, socket.assigns.text)
        {:noreply, socket}
      end

  ## Read

      def handle_event("paste", _params, socket) do
        case Mob.Clipboard.get(socket) do
          {:clipboard, :ok, text} -> {:noreply, Mob.Socket.assign(socket, :field, text)}
          {:clipboard, :empty}    -> {:noreply, socket}
        end
      end

  `get/1` dispatches to the main thread synchronously (same model as
  `safe_area/0`) — fast enough to call from any callback.
  """

  @doc """
  Write `text` to the system clipboard. Fire-and-forget; returns the socket.
  """
  @spec put(Mob.Socket.t(), binary()) :: Mob.Socket.t()
  def put(socket, text) when is_binary(text) do
    :mob_nif.clipboard_put(text)
    socket
  end

  @doc """
  Read the current clipboard text synchronously.

  Returns `{:clipboard, :ok, text}` or `{:clipboard, :empty}`.
  """
  @spec get(Mob.Socket.t()) :: {:clipboard, :ok, binary()} | {:clipboard, :empty}
  def get(_socket) do
    case :mob_nif.clipboard_get() do
      {:ok, text} -> {:clipboard, :ok, text}
      :empty -> {:clipboard, :empty}
    end
  end
end
