defmodule Mob do
  @moduledoc """
  Mob — BEAM-on-device mobile framework for Elixir.

  The top-level module provides convenience re-exports and the application
  entry point. Most app code will use `Mob.Screen` and `Mob.Socket` directly.

  ## Quick start

      defmodule MyApp.HomeScreen do
        use Mob.Screen

        def mount(_params, _session, socket) do
          {:ok, Mob.Socket.assign(socket, :title, "Hello, Mob!")}
        end

        def render(assigns) do
          %{
            type: :column,
            props: %{padding: 16},
            children: [
              %{type: :text, props: %{text: assigns.title, text_size: 24}, children: []}
            ]
          }
        end
      end
  """

  defdelegate assign(socket, key, value), to: Mob.Socket
  defdelegate assign(socket, kw), to: Mob.Socket
end
