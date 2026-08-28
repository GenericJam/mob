defmodule Mob.Nav.MultiStackTest do
  @moduledoc """
  `Mob.App.tab_bar/1` end to end: two declared stacks, each owning its own
  history and its own live screen state across switches.

  Before MOB-109 `{:switch_tab, _}` was cleared as a no-op with a comment
  claiming the renderer handled it, so every assertion here failed — one
  `nav_history` cannot hold two stacks.
  """
  use ExUnit.Case, async: false

  # Sibling modules in nested defmodule blocks don't auto-alias — fully
  # qualified names via attributes, matching Mob.Nav.ScreenNavTest.
  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.Nav.MultiStackTest.HomeDetailScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}
    def render(assigns), do: %{type: :text, props: %{text: "home #{assigns.count}"}, children: []}

    def handle_event("bump", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_event("push_detail", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}

    def handle_event("to_nowhere", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :does_not_exist)}
  end

  defmodule HomeDetailScreen do
    use Mob.Screen

    def mount(_params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :where, :home_detail)}

    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.where}"}, children: []}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("back", _, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    @detail Mob.Nav.MultiStackTest.SettingsDetailScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :theme, :light)}

    def render(assigns),
      do: %{type: :text, props: %{text: "settings #{assigns.theme}"}, children: []}

    def handle_event("dark", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :theme, :dark)}

    def handle_event("push_detail", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule SettingsDetailScreen do
    use Mob.Screen

    def mount(_params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :where, :settings_detail)}

    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.where}"}, children: []}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App

    @home Mob.Nav.MultiStackTest.HomeScreen
    @settings Mob.Nav.MultiStackTest.SettingsScreen

    def navigation(_) do
      tab_bar([
        stack(:home, root: @home, title: "Home"),
        stack(:settings, root: @settings, title: "Settings")
      ])
    end
  end

  setup do
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} = Mob.Nav.Registry.start_link(TabApp)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, screen} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> if Process.alive?(screen), do: GenServer.stop(screen) end)

    %{screen: screen}
  end

  describe "switching stacks" do
    test "first switch mounts the target stack's declared root", %{screen: screen} do
      Mob.Screen.dispatch(screen, "to_settings", %{})
      assert Mob.Screen.get_current_module(screen) == SettingsScreen
    end

    test "switching back restores the previous stack's screen", %{screen: screen} do
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})
      assert Mob.Screen.get_current_module(screen) == HomeScreen
    end

    test "switching to an undeclared stack leaves navigation untouched", %{screen: screen} do
      Mob.Screen.dispatch(screen, "to_nowhere", %{})
      assert Mob.Screen.get_current_module(screen) == HomeScreen
    end

    test "switching to the active stack is a no-op", %{screen: screen} do
      Mob.Screen.dispatch(screen, "to_home", %{})
      assert Mob.Screen.get_current_module(screen) == HomeScreen
      assert Mob.Screen.get_socket(screen).assigns.count == 0
    end
  end

  describe "state preservation" do
    test "an inactive stack keeps its screen assigns", %{screen: screen} do
      Mob.Screen.dispatch(screen, "bump", %{})
      Mob.Screen.dispatch(screen, "bump", %{})
      assert Mob.Screen.get_socket(screen).assigns.count == 2

      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})

      assert Mob.Screen.get_socket(screen).assigns.count == 2
    end

    test "returning to a stack does not re-run mount", %{screen: screen} do
      # mount/3 resets count to 0, so a surviving non-zero count proves the
      # socket was restored rather than the root re-mounted.
      Mob.Screen.dispatch(screen, "bump", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})

      assert Mob.Screen.get_socket(screen).assigns.count == 1
    end

    test "the other stack keeps its own assigns too", %{screen: screen} do
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "dark", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})

      assert Mob.Screen.get_socket(screen).assigns.theme == :dark
    end
  end

  describe "independent histories" do
    test "each stack pushes onto its own history", %{screen: screen} do
      Mob.Screen.dispatch(screen, "push_detail", %{})
      assert length(Mob.Screen.get_nav_history(screen)) == 1

      # The settings stack has never been visited — its history starts empty
      # rather than inheriting home's.
      Mob.Screen.dispatch(screen, "to_settings", %{})
      assert Mob.Screen.get_nav_history(screen) == []
    end

    test "an inactive stack's history survives the round trip", %{screen: screen} do
      Mob.Screen.dispatch(screen, "push_detail", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})

      assert Mob.Screen.get_current_module(screen) == HomeDetailScreen
      assert [{HomeScreen, _}] = Mob.Screen.get_nav_history(screen)
    end

    test "both stacks hold a deep history at the same time", %{screen: screen} do
      Mob.Screen.dispatch(screen, "push_detail", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "push_detail", %{})

      assert Mob.Screen.get_current_module(screen) == SettingsDetailScreen
      assert [{SettingsScreen, _}] = Mob.Screen.get_nav_history(screen)

      Mob.Screen.dispatch(screen, "to_home", %{})
      assert Mob.Screen.get_current_module(screen) == HomeDetailScreen
      assert [{HomeScreen, _}] = Mob.Screen.get_nav_history(screen)
    end

    test "popping in one stack does not touch the other", %{screen: screen} do
      Mob.Screen.dispatch(screen, "push_detail", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "push_detail", %{})
      Mob.Screen.dispatch(screen, "to_home", %{})

      Mob.Screen.dispatch(screen, "back", %{})
      assert Mob.Screen.get_current_module(screen) == HomeScreen
      assert Mob.Screen.get_nav_history(screen) == []

      Mob.Screen.dispatch(screen, "to_settings", %{})
      assert Mob.Screen.get_current_module(screen) == SettingsDetailScreen
      assert length(Mob.Screen.get_nav_history(screen)) == 1
    end

    test "back at a secondary stack's root returns to the first stack", %{screen: screen} do
      # Not exit_app: that would discard every parked stack, which is the state
      # this whole feature exists to keep.
      Mob.Screen.dispatch(screen, "bump", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      assert Mob.Screen.get_nav_history(screen) == []

      send(screen, {:mob, :back})
      :sys.get_state(screen)

      assert Mob.Screen.get_current_module(screen) == HomeScreen
      assert Mob.Screen.get_socket(screen).assigns.count == 1
    end

    test "back at the first stack's root does not switch away", %{screen: screen} do
      # :no_render mode means exit_app/0 is not called; the screen stays put.
      send(screen, {:mob, :back})
      :sys.get_state(screen)

      assert Mob.Screen.get_current_module(screen) == HomeScreen
    end

    test "the back gesture pops the active stack only", %{screen: screen} do
      Mob.Screen.dispatch(screen, "push_detail", %{})
      Mob.Screen.dispatch(screen, "to_settings", %{})
      Mob.Screen.dispatch(screen, "push_detail", %{})

      send(screen, {:mob, :back})
      :sys.get_state(screen)

      assert Mob.Screen.get_current_module(screen) == SettingsScreen

      Mob.Screen.dispatch(screen, "to_home", %{})
      assert Mob.Screen.get_current_module(screen) == HomeDetailScreen
    end
  end
end
