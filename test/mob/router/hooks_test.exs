defmodule Mob.Router.HooksTest do
  # Hooks are VM-global (persistent_term): not async.
  use ExUnit.Case, async: false

  alias Mob.Router.Hooks

  defmodule HomeScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_info({:tap, :push}, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.Router.HooksTest.DetailScreen)}

    def handle_info({:tap, :reset}, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, Mob.Router.HooksTest.DetailScreen)}

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  defmodule DetailScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "detail"}, children: []}
  end

  defmodule UpdateScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "update"}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: Mob.Router.HooksTest.HomeScreen)
  end

  # A hook whose answer the test sets; it reports every call.
  defmodule Probe do
    def before_navigate(test_pid, dest) do
      send(test_pid, {:hook_called, dest})

      case :persistent_term.get({__MODULE__, :verdict}, :ok) do
        :raise -> raise "hook bug"
        verdict -> verdict
      end
    end

    def first_render(test_pid), do: send(test_pid, :first_render)
  end

  defmodule StubNif do
    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def take_launch_notification, do: :none
    def clear_taps, do: :ok
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def set_root(_json), do: :ok
  end

  setup do
    Mob.Test.ProcessHelpers.stop_if_running(Mob.Nav.Registry)
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)

    hook = {Probe, :before_navigate, [self()]}
    Hooks.register(:before_navigate, hook)

    on_exit(fn ->
      Hooks.unregister(:before_navigate, hook)
      :persistent_term.erase({Probe, :verdict})
      Mob.Test.ProcessHelpers.stop_pid(registry)
    end)

    {:ok, router} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(router) end)
    %{router: router, screen: Mob.Screen.get_screen_pid(router)}
  end

  # The hook runs inside the router while it handles the navigation, so once
  # the hook has reported, a call to the router returns after navigation.
  # Returns {destination the hook saw, screen current afterwards}.
  defp navigate(router, screen, tap) do
    send(screen, {:tap, tap})
    assert_receive {:hook_called, dest}
    {dest, GenServer.call(router, :get_current_module)}
  end

  test "a hook that answers :ok sees the destination and lets it mount", %{
    router: router,
    screen: screen
  } do
    assert navigate(router, screen, :push) == {DetailScreen, DetailScreen}
  end

  test "a redirect mounts the hook's screen instead", %{router: router, screen: screen} do
    :persistent_term.put({Probe, :verdict}, {:redirect, UpdateScreen})
    assert navigate(router, screen, :push) == {DetailScreen, UpdateScreen}
  end

  test "a refusal leaves navigation where it was", %{router: router, screen: screen} do
    :persistent_term.put({Probe, :verdict}, {:error, :not_now})
    assert navigate(router, screen, :reset) == {DetailScreen, HomeScreen}
  end

  @tag :capture_log
  test "a hook that raises or answers nonsense counts as a refusal", %{
    router: router,
    screen: screen
  } do
    :persistent_term.put({Probe, :verdict}, :maybe)
    assert navigate(router, screen, :push) == {DetailScreen, HomeScreen}

    :persistent_term.put({Probe, :verdict}, :raise)
    assert navigate(router, screen, :push) == {DetailScreen, HomeScreen}
  end

  test "registering the same hook twice calls it once", %{router: router, screen: screen} do
    Hooks.register(:before_navigate, {Probe, :before_navigate, [self()]})
    assert navigate(router, screen, :push) == {DetailScreen, DetailScreen}
    refute_received {:hook_called, _}
  end

  describe ":after_first_render" do
    setup do
      services = [Mob.Sender, Mob.Listener, Mob.ComponentRegistry]
      for name <- services, pid = Process.whereis(name), do: Mob.Test.ProcessHelpers.stop_pid(pid)
      {:ok, _} = Mob.ComponentRegistry.start_link()

      hook = {Probe, :first_render, [self()]}
      Hooks.register(:after_first_render, hook)
      Hooks.__reset_first_render__()

      on_exit(fn ->
        Hooks.unregister(:after_first_render, hook)
        Mob.Test.ProcessHelpers.stop_all(Enum.map(services, &Process.whereis/1))
      end)
    end

    test "fires once after the root screen's first paint, not on later router starts" do
      {:ok, router} = Mob.Router.start_root(HomeScreen, %{}, nif: StubNif)
      assert_receive :first_render
      Mob.Test.ProcessHelpers.stop_pid(router)

      {:ok, again} = Mob.Router.start_root(HomeScreen, %{}, nif: StubNif)
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(again) end)
      refute_receive :first_render, 100
    end
  end
end
