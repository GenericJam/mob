defmodule Mob.RouterHotPathTest do
  @moduledoc """
  The router must not be in the per-message path.

  This is the constraint MOB-113 exists to guarantee and the reason one process
  per screen is affordable at all: an earlier costing of this design assumed a
  router in the loop and concluded per-screen processes could not escape a hop
  per message.

  Asserted by tracing the router's mailbox rather than by reasoning about the
  code, so it keeps holding when someone adds a message.
  """
  use ExUnit.Case, async: false

  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.RouterHotPathTest.DetailScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}
    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.count}"}, children: []}

    def handle_info({:tap, :bump}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_info({:change, :field, value}, socket),
      do: {:noreply, Mob.Socket.assign(socket, :typed, value)}

    def handle_info({:tap, :go}, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  defmodule DetailScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "detail"}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.RouterHotPathTest.HomeScreen
    def navigation(_), do: stack(:home, root: @home)
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  setup do
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, router} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> stop_safely(router) end)

    screen = Mob.Screen.get_screen_pid(router)
    %{router: router, screen: screen}
  end

  # Trace the router's receives while `fun` runs, and return what it got.
  # Nothing may call the router during the window — that would be a message too.
  defp router_messages(router, fun) do
    tracer = self()
    :erlang.trace(router, true, [:receive, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(router, false, [:receive])
    end

    collect_trace([])
  end

  defp collect_trace(acc) do
    receive do
      {:trace, _pid, :receive, msg} -> collect_trace([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "the router is not in the per-message path" do
    test "an ordinary tap on the active screen never reaches it", %{
      router: router,
      screen: screen
    } do
      # What Mob.Listener does on a real tap: straight to the screen's own pid.
      messages =
        router_messages(router, fn ->
          send(screen, {:tap, :bump})
          :sys.get_state(screen)
        end)

      assert messages == []
      assert Mob.Screen.get_socket(router).assigns.count == 1
    end

    test "a value-carrying event never reaches it either", %{router: router, screen: screen} do
      messages =
        router_messages(router, fn ->
          send(screen, {:change, :field, "hello"})
          :sys.get_state(screen)
        end)

      assert messages == []
    end

    test "a burst of messages produces no router traffic at all", %{
      router: router,
      screen: screen
    } do
      messages =
        router_messages(router, fn ->
          for _ <- 1..50, do: send(screen, {:tap, :bump})
          :sys.get_state(screen)
        end)

      assert messages == []
      assert Mob.Screen.get_socket(router).assigns.count == 50
    end
  end

  describe "navigation does reach the router" do
    test "a nav action from a screen callback arrives", %{router: router, screen: screen} do
      messages =
        router_messages(router, fn ->
          send(screen, {:tap, :go})
          :sys.get_state(screen)
          # Give the router a moment to receive the forwarded action.
          Process.sleep(20)
        end)

      assert Enum.any?(messages, &match?({:nav_action, {:push, _, _}, ^screen}, &1)),
             "expected a {:nav_action, …} from the screen, got: #{inspect(messages)}"
    end

    test "and the navigation actually happens", %{router: router, screen: screen} do
      send(screen, {:tap, :go})
      :sys.get_state(screen)
      :sys.get_state(router)

      assert Mob.Screen.get_current_module(router) == DetailScreen
      assert [{HomeScreen, _}] = Mob.Screen.get_nav_history(router)
    end
  end
end
