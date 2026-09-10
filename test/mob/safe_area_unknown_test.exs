defmodule Mob.SafeAreaUnknownTest do
  use ExUnit.Case, async: false

  # MOB-166. `ensure_safe_area/3` used to stop asking as soon as the `:safe_area`
  # assign existed. The BEAM can reach a paint before iOS has a window — a
  # background launch connects no window scene at all, and an iOS 15+ prewarmed
  # launch runs `didFinishLaunchingWithOptions:` long before the user taps the
  # icon — and `nif_safe_area` could only answer zeros in that case. So a screen
  # that painted once too early spent the rest of its life laid out under the
  # notch and home indicator.
  #
  # The NIF now answers `:no_window` distinctly. Zeros are still assigned (screens
  # read `assigns.safe_area` directly and a missing key would be a KeyError in
  # render) but they are marked unconfirmed, so the next paint asks again.

  defmodule Screen do
    @moduledoc false
    use Mob.Screen

    def mount(_p, _s, socket), do: {:ok, Mob.Socket.assign(socket, :n, 0)}

    # Changing an assign is what makes the router repaint.
    def handle_info(:repaint, socket),
      do: {:noreply, Mob.Socket.assign(socket, :n, System.unique_integer([:positive]))}

    def handle_info(_other, socket), do: {:noreply, socket}

    def render(assigns),
      do: %{
        type: :text,
        props: %{text: "#{assigns.n} #{inspect(assigns.safe_area)}"},
        children: []
      }
  end

  defmodule Nif do
    @moduledoc false
    use Agent

    # `:no_window` for the first `n` reads, then real insets — a window that
    # appears after the app has already started painting.
    def start(n), do: Agent.start_link(fn -> {n, 0} end, name: __MODULE__)

    def safe_area do
      Agent.get_and_update(__MODULE__, fn
        {0, reads} -> {{47.0, 0.0, 34.0, 0.0}, {0, reads + 1}}
        {n, reads} -> {:no_window, {n - 1, reads + 1}}
      end)
    end

    def reads, do: Agent.get(__MODULE__, fn {_n, r} -> r end)
    def platform, do: :ios
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  setup do
    Mob.Test.ProcessHelpers.stop_if_running(Nif)
    :ok
  end

  defp start_screen do
    {:ok, pid} = Mob.Router.start_root(Screen, %{}, nif: Nif)
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(pid) end)
    pid
  end

  defp repaint(pid) do
    send(pid, :repaint)
    # A call to the router is not an ordering barrier for a message it forwards
    # to the screen, so sync with the screen itself.
    pid |> Mob.Router.get_screen_pid() |> :sys.get_state()
    Mob.Router.get_socket(pid)
  end

  test "a screen that painted before the window picks up the real insets later" do
    # Enough :no_window reads to cover mount and the first paint, so the screen
    # is fully started while iOS still has no window.
    {:ok, _} = Nif.start(2)
    pid = start_screen()

    assert repaint(pid).assigns.safe_area == %{top: 47.0, right: 0.0, bottom: 34.0, left: 0.0},
           "the screen kept a reading taken before the window existed"
  end

  test "the assign is present, as zeros, while there is no window" do
    # Screens read `assigns.safe_area` directly, so it must never be missing.
    {:ok, _} = Nif.start(1_000)
    pid = start_screen()

    assert Mob.Router.get_socket(pid).assigns.safe_area ==
             %{top: 0.0, right: 0.0, bottom: 0.0, left: 0.0}
  end

  test "a confirmed reading is not re-read on later paints" do
    # Each read is a hop to the main thread. A real answer does not change under
    # the screen, so asking again every paint would be pure cost.
    {:ok, _} = Nif.start(0)
    pid = start_screen()

    repaint(pid)
    settled = Nif.reads()
    repaint(pid)
    repaint(pid)

    assert Nif.reads() == settled, "safe_area was re-read after it was confirmed"
  end
end
