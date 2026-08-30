defmodule Mob.Nav.TabTransitionTest do
  @moduledoc """
  Directional tab transitions from the socket action through the native NIF.

  These run in `:render`: action-shape tests alone cannot prove that the
  selected transition survives router switching and reaches native paint.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule CrashControl do
    def start, do: Agent.start(fn -> false end, name: __MODULE__)
    def crash_next, do: Agent.update(__MODULE__, fn _ -> true end)

    def take do
      Agent.get_and_update(__MODULE__, fn crash? -> {crash?, false} end)
    end
  end

  defmodule HomeScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_event("settings_default", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("settings_push", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings, transition: :push)}

    def handle_event("home_push", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home, transition: :push)}

    def handle_event("noop", _, socket), do: {:noreply, socket}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      if CrashControl.take(), do: raise("requested render crash")
      %{type: :text, props: %{text: "settings"}, children: []}
    end

    def handle_event("home_pop", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home, transition: :pop)}

    def handle_event("settings_pop", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings, transition: :pop)}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App

    @home Mob.Nav.TabTransitionTest.HomeScreen
    @settings Mob.Nav.TabTransitionTest.SettingsScreen

    def navigation(_) do
      tab_bar([
        stack(:home, root: @home, title: "Home"),
        stack(:settings, root: @settings, title: "Settings")
      ])
    end
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

    def set_transition(transition) do
      Agent.update(__MODULE__, &[transition | &1])
      :ok
    end
  end

  setup do
    for name <- [Mob.Nav.Registry, Mob.Sender, Mob.Listener, Mob.ComponentRegistry],
        pid = Process.whereis(name) do
      stop_safely(pid)
    end

    {:ok, components} = Mob.ComponentRegistry.start_link()
    {:ok, crash_control} = CrashControl.start()
    {:ok, recording} = RecordingNif.start()
    {:ok, registry} = Mob.Nav.Registry.start_link(TabApp)
    {:ok, router} = Mob.Router.start_root(HomeScreen, %{}, nif: RecordingNif)

    on_exit(fn ->
      stop_safely(router)
      stop_safely(registry)
      stop_safely(components)
      stop_safely(crash_control)

      for name <- [Mob.Sender, Mob.Listener], pid = Process.whereis(name) do
        stop_safely(pid)
      end

      stop_safely(recording)
    end)

    # The router queues initial paint from its process. Dispatching through the
    # same router drains that screen cast and performs a synchronous repaint,
    # so no cross-sender ordering race can record the initial :none afterward.
    Mob.Router.dispatch(router, "noop", %{})
    RecordingNif.reset()
    %{router: router}
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp transitions do
    Mob.Sender.sync(:infinity)
    RecordingNif.transitions()
  end

  test "a directional transition reaches native on first mount and restore", %{router: router} do
    Mob.Router.dispatch(router, "settings_push", %{})
    assert List.last(transitions()) == :push
    assert Mob.Router.get_current_module(router) == SettingsScreen

    Mob.Router.dispatch(router, "home_pop", %{})
    assert List.last(transitions()) == :pop
    assert Mob.Router.get_current_module(router) == HomeScreen
  end

  test "legacy switch_tab/2 remains an unanimated swap", %{router: router} do
    Mob.Router.dispatch(router, "settings_default", %{})
    assert List.last(transitions()) == :none
    assert Mob.Router.get_current_module(router) == SettingsScreen
  end

  test "rapid alternating transitions retain their order", %{router: router} do
    Mob.Router.dispatch(router, "settings_push", %{})
    Mob.Router.dispatch(router, "home_pop", %{})
    Mob.Router.dispatch(router, "settings_push", %{})
    Mob.Router.dispatch(router, "home_pop", %{})

    assert transitions() == [:push, :pop, :push, :pop]
    assert Mob.Router.get_current_module(router) == HomeScreen
  end

  test "reselecting the active tab stays a no-op", %{router: router} do
    Mob.Router.dispatch(router, "home_push", %{})
    assert List.last(transitions()) == :none
    assert Mob.Router.get_current_module(router) == HomeScreen
  end

  test "a render crash cannot strand an activation frame", %{router: router} do
    original_pid = Mob.Router.get_screen_pid(router)
    CrashControl.crash_next()

    capture_log(fn ->
      Mob.Router.dispatch(router, "settings_push", %{})
      # Drain the linked screen's EXIT and the replacement's first paint.
      :sys.get_state(router)
      :sys.get_state(router)
    end)

    Mob.Sender.sync(:infinity)

    assert Mob.Router.get_current_module(router) == SettingsScreen
    assert Mob.Router.get_screen_pid(router) != original_pid
    assert Process.alive?(Mob.Router.get_screen_pid(router))
    assert List.last(RecordingNif.transitions()) == :push
  end
end
