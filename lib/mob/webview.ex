defmodule Mob.WebView do
  @moduledoc """
  Bidirectional JS bridge for the native WebView component.

  Use `Mob.UI.webview/1` to embed the component, then call these functions
  from `handle_info` to communicate with the page.

  JS side — inject `window.mob` is injected automatically by the native layer:

      // Send a message to Elixir
      window.mob.send({ event: "clicked", id: 42 })

      // Receive a message from Elixir
      window.mob.onMessage(function(data) { console.log(data) })

  Elixir side:

      def handle_info({:webview, :message, %{"event" => "clicked", "id" => id}}, socket) do
        {:noreply, socket}
      end

      def handle_info({:webview, :blocked, url}, socket) do
        # A navigation attempt was blocked by the allow: whitelist
        {:noreply, socket}
      end

  ## Several windows

  On an iPad showing several windows of the app (`Mob.Scene`), each call acts
  on the WebView in the window of `socket`'s screen, and `{:webview, …}`
  messages reach the screen of the window the page is in.
  """

  @doc """
  Evaluate arbitrary JavaScript in the current WebView and return the result
  asynchronously via `handle_info({:webview, :eval_result, result}, socket)`.
  """
  @spec eval_js(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def eval_js(socket, code) when is_binary(code) do
    case scene(socket) do
      nil -> :mob_nif.webview_eval_js(code)
      scene -> :mob_nif.webview_eval_js(scene, code)
    end

    socket
  end

  @doc """
  Push a message from Elixir into the WebView page. Calls `window.mob._dispatch(json)`
  in JS, which delivers the data to all `window.mob.onMessage` handlers.
  """
  @spec post_message(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def post_message(socket, data) do
    json = :json.encode(data)
    case scene(socket) do
      nil -> :mob_nif.webview_post_message(json)
      scene -> :mob_nif.webview_post_message(scene, json)
    end

    socket
  end

  # The window scene of a Mob screen's socket; nil for the primary window's
  # screens and on platforms without scenes, which use the original arities.
  defp scene(%Mob.Socket{} = socket), do: Mob.Scene.of(socket)
  defp scene(_other), do: nil
end
