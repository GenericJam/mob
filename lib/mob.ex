defmodule Mob do
  @moduledoc """
  Mob — BEAM-on-device mobile framework for Elixir.

  OTP runs on the device. Screens are GenServers. The UI is rendered by
  Compose (Android) and SwiftUI (iOS) via a thin NIF. No server required.

  ## Quick start

      defmodule MyApp.HomeScreen do
        use Mob.Screen

        def mount(_params, _session, socket) do
          {:ok, Mob.Socket.assign(socket, :title, "Hello, Mob!")}
        end

        def render(assigns) do
          %{
            type:  :column,
            props: %{padding: :space_md},
            children: [
              %{type: :text, props: %{text: assigns.title, text_size: :xl}, children: []}
            ]
          }
        end
      end

  ## Modules

  - `Mob.App` — app entry point and navigation declaration
  - `Mob.Screen` — screen behaviour and GenServer wrapper
  - `Mob.Socket` — assigns and navigation API
  - `Mob.Theme` — design token system
  - `Mob.Renderer` — component tree serialisation
  - `Mob.Test` — live device inspection and testing helpers

  See the [Getting Started](guides/getting_started.html) guide to create your
  first app. See [Architecture & Prior Art](guides/architecture.html) for how
  Mob compares to LiveView Native, Elixir Desktop, React Native, Flutter, and
  native development.
  """

  defdelegate assign(socket, key, value), to: Mob.Socket
  defdelegate assign(socket, kw), to: Mob.Socket

  @doc """
  A writable, app-private directory for runtime data — DB files, caches,
  downloaded assets, anything you write at runtime.

  On device this is `MOB_DATA_DIR`, set by the BEAM launcher to the platform's
  persistent app-private location (iOS `NSDocumentDirectory`, Android
  `getFilesDir()`). Off device (host/dev/tests) it falls back to `$HOME`, then
  the current working directory. The directory is created if missing.

  Use this — **not** `MOB_BEAMS_DIR`. `MOB_BEAMS_DIR` points inside the signed,
  read-only `.app` bundle on iOS, so writing there fails with `:eperm`; it
  happens to be writable on Android, which is how that trap stays hidden until
  an app ships to iOS.

      path = Path.join(Mob.data_dir(), "my.db")

  See `data_dir/1` for a created subdirectory.
  """
  @spec data_dir() :: String.t()
  def data_dir do
    dir =
      System.get_env("MOB_DATA_DIR") ||
        System.get_env("HOME") ||
        File.cwd!()

    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Like `data_dir/0` but returns (and creates) the `sub` directory beneath it,
  e.g. `Mob.data_dir("audio_cache")`.
  """
  @spec data_dir(String.t()) :: String.t()
  def data_dir(sub) when is_binary(sub) do
    dir = Path.join(data_dir(), sub)
    File.mkdir_p!(dir)
    dir
  end
end
