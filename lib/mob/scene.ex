defmodule Mob.Scene do
  @moduledoc """
  Window scenes: several windows of one app (MOB-245).

  On iPad every window of an app is a scene, and an app can show several side
  by side (Split View, Stage Manager) or switch between them. In a mob app
  they all run in the one BEAM, and each has its own router, navigation and
  screens: the window the app started in runs the root screen from
  `Mob.Screen.start_root/2`, and every further window starts on that same
  screen with the same params, then navigates on its own.

  ## Opting in

  iOS shows one window per app unless `Info.plist` says otherwise. Set it in
  `mob.exs`:

      config :mob_dev, multi_window: true

  mob_dev writes `UIApplicationSupportsMultipleScenes` into the built app's
  `Info.plist` (dev builds and `mix mob.release`). Rebuild natively after
  changing it.

  ## Opening a window

  The user can always open one from the app switcher or by dragging. To offer
  a button, show it only where it can work. `supported?/0` asks the main
  thread, and the answer never changes while the app runs, so read it once in
  `mount/3`, not in `render/1`:

      def mount(_params, _session, socket) do
        {:ok, Mob.Socket.assign(socket, :multi_window, Mob.Scene.supported?())}
      end

      def render(assigns) do
        ~MOB\"\"\"
        <Column>
          <Button :if={@multi_window} text="New window" on_tap={{self(), :new_window}} />
        </Column>
        \"\"\"
      end

      def handle_info({:tap, :new_window}, socket) do
        Mob.Scene.request_new()
        {:noreply, socket}
      end

      # The system can still refuse, e.g. on iPhone Duo's outer display.
      def handle_info({:mob_scene, :request_failed, _reason}, socket), do: {:noreply, socket}

  ## What each window gets

  * Its own navigation: `push_screen/2` and friends act on the window the
    screen is in, and so does the back gesture.
  * Its own `:safe_area` and `:size_class` assigns: two windows side by side
    are often different classes.
  * Alerts and action sheets (`Mob.Alert`) shown by a screen appear in that
    screen's window, and their results come back to it.

  Shared by every window: the app's processes, `Mob.State`, persisted screen
  state (one `Mob.ScreenState` entry per screen module, last write wins), and
  notifications, which go to the window the app started in unless a process
  registered for them.

  A window the user closes, or one iPadOS discards in the background to save
  memory, has its screens stopped (persisted screens dump their state); if it
  comes back it starts on the root screen again. The last window is never
  stopped, so a single-window app keeps its state as it always has.

  `Mob.Test.screens/1` lists what every window shows, and `Mob.Test` helpers
  take `scene:` to address one. See
  `decisions/2026-10-02-one-router-per-window-scene.md`.
  """

  @typedoc "A window scene id: `UISceneSession.persistentIdentifier` on iOS, `nil` where there is none."
  @type id :: String.t() | nil

  @doc """
  Ask the system for a new window of this app.

  `:ok` means the request was made; the new window then connects like any
  other and shows the root screen. `{:error, :unsupported}` when this app or
  device can't show more than one window (no `multi_window: true`, an iPhone,
  or Android). The system can still refuse a request it accepted, and then
  sends `{:mob_scene, :request_failed, reason}` to the calling process.
  """
  @spec request_new() :: :ok | {:error, :unsupported}
  def request_new do
    case :mob_nif.scene_request() do
      :ok -> :ok
      _unsupported -> {:error, :unsupported}
    end
  catch
    :error, reason when reason in [:undef, :not_loaded] -> {:error, :unsupported}
  end

  @doc """
  Whether this app can show more than one window here: the app opted in and
  the device supports it. Use it to decide whether to offer a "New window"
  button. Always `false` on Android. A synchronous main-thread round trip
  whose answer is fixed for the life of the app: call it from `mount/3`.
  """
  @spec supported?() :: boolean()
  def supported? do
    :mob_nif.scene_multiple_supported() == true
  catch
    :error, reason when reason in [:undef, :not_loaded] -> false
  end

  @doc """
  The window scene id of `socket`'s screen: a scene id for screens of every
  further window, `nil` for screens of the window the app started in (whose
  router follows native's default scene rather than one id) and on platforms
  without scenes.
  """
  @spec of(Mob.Socket.t()) :: id()
  def of(%Mob.Socket{__mob__: mob}), do: Map.get(mob, :scene)

  @doc """
  Every window and the router showing it, as `{scene_id, router_pid}`: the
  window the app started in first. See `Mob.Scenes.list/0`.
  """
  @spec list() :: [{id(), pid()}]
  defdelegate list, to: Mob.Scenes
end
