defmodule Mob.Nav.ResetTransitionTest do
  @moduledoc """
  `reset_to/4`'s `:transition` option, end to end.

  The socket-level tests assert the nav action's shape; these assert the thing
  the option exists for — that the chosen animation actually reaches
  `set_transition/1` on the native boundary. A reset that recorded `:push` in
  its action and still painted `:reset` would pass a shape test and be useless.

  Runs in `:render` with an injected NIF, since `do_paint` short-circuits under
  `:no_render` and the transition would never be observable.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule HomeScreen do
    use Mob.Screen

    @other Mob.Nav.ResetTransitionTest.OtherScreen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_event("reset_default", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other)}

    def handle_event("reset_push", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other, %{}, transition: :push)}

    def handle_event("reset_pop", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other, %{}, transition: :pop)}
  end

  defmodule OtherScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "other"}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Nav.ResetTransitionTest.HomeScreen
    def navigation(_), do: stack(:home, root: @home)
  end

  defmodule RecordingNif do
    def start, do: Agent.start(fn -> [] end, name: __MODULE__)
    def transitions, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def take_launch_notification, do: :none
    def clear_taps, do: :ok
    def register_tap(_), do: 0
    def set_root(_json), do: :ok

    def set_transition(t) do
      Agent.update(__MODULE__, &[t | &1])
      :ok
    end
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # The transition for the frame the reset painted, ignoring the initial mount.
  defp last_transition do
    Mob.Sender.sync(:infinity)
    List.last(RecordingNif.transitions())
  end

  setup do
    for name <- [Mob.Nav.Registry, Mob.Sender, Mob.Listener, Mob.ComponentRegistry],
        pid = Process.whereis(name) do
      stop_safely(pid)
    end

    # The render path reconciles components, which needs the registry's table.
    {:ok, components} = Mob.ComponentRegistry.start_link()

    # Stop everything this file caused to start, not just what it started
    # directly. Mob.Router brings up the Sender and Listener under their global
    # names; leaving them behind is what produces cross-file ordering flakes.
    on_exit(fn ->
      stop_safely(components)

      for name <- [Mob.Sender, Mob.Listener], pid = Process.whereis(name) do
        stop_safely(pid)
      end

      case Process.whereis(RecordingNif) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end)

    case Process.whereis(RecordingNif) do
      nil -> RecordingNif.start()
      pid -> Agent.stop(pid) && RecordingNif.start()
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, router} = Mob.Router.start_root(HomeScreen, %{}, nif: RecordingNif)
    on_exit(fn -> stop_safely(router) end)

    RecordingNif.reset()
    %{router: router}
  end

  describe "the chosen transition reaches the native boundary" do
    test "a plain reset still cross-fades", %{router: router} do
      Mob.Router.dispatch(router, "reset_default", %{})
      assert last_transition() == :reset
    end

    test "transition: :push paints a push", %{router: router} do
      Mob.Router.dispatch(router, "reset_push", %{})
      assert last_transition() == :push
    end

    test "transition: :pop paints a pop", %{router: router} do
      Mob.Router.dispatch(router, "reset_pop", %{})
      assert last_transition() == :pop
    end

    test "the stack is still replaced, whatever the animation", %{router: router} do
      Mob.Router.dispatch(router, "reset_push", %{})

      assert Mob.Router.get_current_module(router) == OtherScreen
      assert Mob.Router.get_nav_history(router) == []
    end
  end

  describe "an action shape the router does not know" do
    test "is ignored rather than killing navigation and every screen", %{router: router} do
      # Reachable during a hot code push: module loading is not atomic, so a
      # screen already on new code can hand an action to a router still on old
      # code. Unmatched, that is a FunctionClauseError in the owner.
      screen = Mob.Router.get_screen_pid(router)

      log =
        capture_log(fn ->
          :ok = GenServer.call(router, {:navigate, {:reset, OtherScreen, %{}, :push, :extra}})
        end)

      assert log =~ "unrecognised navigation action"
      assert Process.alive?(router)
      assert Process.alive?(screen)
      assert Mob.Router.get_current_module(router) == HomeScreen
    end
  end

  describe "the legacy three-element action" do
    test "still resets, and still cross-fades", %{router: router} do
      # Arrives from Mob.Test.reset_to/3 and from any socket built before a hot
      # code push. Dropping it would break navigation across an upgrade.
      :ok = GenServer.call(router, {:navigate, {:reset, OtherScreen, %{}}})

      assert last_transition() == :reset
      assert Mob.Router.get_current_module(router) == OtherScreen
    end
  end
end
