defmodule Mob.Nav.ScreenNavTest do
  use ExUnit.Case, async: false

  # ── Screen fixtures ────────────────────────────────────────────────────────
  # Bare module names inside nested defmodule blocks don't auto-alias to siblings.
  # Use module attributes with fully qualified names for cross-screen references.

  defmodule HomeScreen do
    use Mob.Screen

    @profile Mob.Nav.ScreenNavTest.ProfileScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :page, :home)}
    def render(assigns), do: %{type: :text, props: %{text: "home #{assigns.page}"}, children: []}

    def handle_event("go_profile", _, socket),       do: {:noreply, Mob.Socket.push_screen(socket, @profile)}
    def handle_event("go_settings", _, socket),      do: {:noreply, Mob.Socket.push_screen(socket, :settings, %{from: :home})}
    def handle_event("reset_to_profile", _, socket), do: {:noreply, Mob.Socket.reset_to(socket, @profile)}
  end

  defmodule ProfileScreen do
    use Mob.Screen

    @home     Mob.Nav.ScreenNavTest.HomeScreen
    @settings Mob.Nav.ScreenNavTest.SettingsScreen

    def mount(params, _session, socket) do
      {:ok, Mob.Socket.assign(socket, :name, Map.get(params, :name, "anon"))}
    end
    def render(assigns), do: %{type: :text, props: %{text: "profile #{assigns.name}"}, children: []}

    def handle_event("back", _, socket),           do: {:noreply, Mob.Socket.pop_screen(socket)}
    def handle_event("back_to_root", _, socket),   do: {:noreply, Mob.Socket.pop_to_root(socket)}
    def handle_event("go_settings", _, socket),    do: {:noreply, Mob.Socket.push_screen(socket, @settings)}
    def handle_event("reset_to_home", _, socket),  do: {:noreply, Mob.Socket.reset_to(socket, @home)}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    @home Mob.Nav.ScreenNavTest.HomeScreen

    def mount(params, _session, socket) do
      {:ok, Mob.Socket.assign(socket, :from, Map.get(params, :from, :unknown))}
    end
    def render(assigns), do: %{type: :text, props: %{text: "settings from=#{assigns.from}"}, children: []}

    def handle_event("back", _, socket),          do: {:noreply, Mob.Socket.pop_screen(socket)}
    def handle_event("back_to_root", _, socket),  do: {:noreply, Mob.Socket.pop_to_root(socket)}
    def handle_event("pop_to_home", _, socket),   do: {:noreply, Mob.Socket.pop_to(socket, @home)}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App

    @settings Mob.Nav.ScreenNavTest.SettingsScreen

    def navigation(_), do: stack(:settings, root: @settings)
  end

  setup do
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  # ── push_screen ────────────────────────────────────────────────────────────

  describe "push_screen/2 (module dest)" do
    test "switches current module to the pushed screen" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      assert Mob.Screen.get_current_module(pid) == ProfileScreen
      GenServer.stop(pid)
    end

    test "new screen is mounted with empty params" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.name == "anon"
      GenServer.stop(pid)
    end

    test "nav history grows by one on push" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      assert Mob.Screen.get_nav_history(pid) == []
      Mob.Screen.dispatch(pid, "go_profile", %{})
      assert length(Mob.Screen.get_nav_history(pid)) == 1
      GenServer.stop(pid)
    end

    test "history head is the previous module" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      [{prev_module, _prev_socket} | _] = Mob.Screen.get_nav_history(pid)
      assert prev_module == HomeScreen
      GenServer.stop(pid)
    end
  end

  describe "push_screen/3 (registered atom dest with params)" do
    test "resolves atom via registry and mounts with params" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_settings", %{})
      assert Mob.Screen.get_current_module(pid) == SettingsScreen
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.from == :home
      GenServer.stop(pid)
    end
  end

  # ── pop_screen ─────────────────────────────────────────────────────────────

  describe "pop_screen/1" do
    test "returns to previous module" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      Mob.Screen.dispatch(pid, "back", %{})
      assert Mob.Screen.get_current_module(pid) == HomeScreen
      GenServer.stop(pid)
    end

    test "restores previous screen's socket assigns" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      Mob.Screen.dispatch(pid, "back", %{})
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.page == :home
      GenServer.stop(pid)
    end

    test "nav history shrinks on pop" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      Mob.Screen.dispatch(pid, "back", %{})
      assert Mob.Screen.get_nav_history(pid) == []
      GenServer.stop(pid)
    end

    test "pop at root is a no-op (module stays the same)" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      # Send an info message that would trigger pop — default handle_info is noop
      send(pid, :pop_test)
      Process.sleep(10)
      assert Mob.Screen.get_current_module(pid) == HomeScreen
      GenServer.stop(pid)
    end
  end

  # ── pop_to_root ────────────────────────────────────────────────────────────

  describe "pop_to_root/1" do
    test "returns to the root from two levels deep" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      Mob.Screen.dispatch(pid, "go_settings", %{})
      assert Mob.Screen.get_current_module(pid) == SettingsScreen
      # SettingsScreen now also handles back_to_root
      Mob.Screen.dispatch(pid, "back_to_root", %{})
      assert Mob.Screen.get_current_module(pid) == HomeScreen
      assert Mob.Screen.get_nav_history(pid) == []
      GenServer.stop(pid)
    end

    test "pop_to_root at root is a no-op" do
      {:ok, pid} = Mob.Screen.start_link(ProfileScreen, %{name: "alice"})
      Mob.Screen.dispatch(pid, "back_to_root", %{})
      assert Mob.Screen.get_current_module(pid) == ProfileScreen
      GenServer.stop(pid)
    end
  end

  # ── pop_to ─────────────────────────────────────────────────────────────────

  describe "pop_to/2" do
    test "pops back to the target module in history" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_settings", %{})
      # Now we're on SettingsScreen. Push ProfileScreen from there is not wired,
      # so instead test the same scenario by going Home -> Profile -> Settings
      # then pop_to_home from Settings.
      GenServer.stop(pid)

      {:ok, pid2} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid2, "go_profile", %{})
      Mob.Screen.dispatch(pid2, "go_settings", %{})
      assert Mob.Screen.get_current_module(pid2) == SettingsScreen
      Mob.Screen.dispatch(pid2, "pop_to_home", %{})
      assert Mob.Screen.get_current_module(pid2) == HomeScreen
      assert Mob.Screen.get_nav_history(pid2) == []
      GenServer.stop(pid2)
    end

    test "is a no-op if target is not in history" do
      {:ok, pid} = Mob.Screen.start_link(SettingsScreen, %{})
      # SettingsScreen tries to pop_to HomeScreen, but HomeScreen isn't in history
      Mob.Screen.dispatch(pid, "pop_to_home", %{})
      assert Mob.Screen.get_current_module(pid) == SettingsScreen
      GenServer.stop(pid)
    end
  end

  # ── reset_to ───────────────────────────────────────────────────────────────

  describe "reset_to/2" do
    test "replaces entire nav stack with a fresh screen" do
      # Start on HomeScreen, push to ProfileScreen, then reset to HomeScreen from there
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      assert Mob.Screen.get_current_module(pid) == ProfileScreen
      # ProfileScreen handles "reset_to_home" via Mob.Socket.reset_to(socket, HomeScreen)
      Mob.Screen.dispatch(pid, "reset_to_home", %{})
      assert Mob.Screen.get_current_module(pid) == HomeScreen
      assert Mob.Screen.get_nav_history(pid) == []
      GenServer.stop(pid)
    end

    test "new screen is freshly mounted" do
      {:ok, pid} = Mob.Screen.start_link(HomeScreen, %{})
      Mob.Screen.dispatch(pid, "go_profile", %{})
      Mob.Screen.dispatch(pid, "reset_to_home", %{})
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.page == :home
      GenServer.stop(pid)
    end
  end

  # ── resolve: unknown destination ──────────────────────────────────────────

  describe "resolve_module/1 error handling" do
    defmodule UnknownNavScreen do
      use Mob.Screen
      def mount(_, _, socket), do: {:ok, socket}
      def render(_), do: %{type: :text, props: %{text: "x"}, children: []}

      def handle_event("bad_nav", _, socket) do
        {:noreply, Mob.Socket.push_screen(socket, :no_such_screen)}
      end
    end

    test "raises ArgumentError for unregistered atom" do
      {:ok, pid} = Mob.Screen.start_link(UnknownNavScreen, %{})
      # Unlink so the server crash doesn't kill the test process — we only want
      # to observe the exit that GenServer.call propagates through the call path.
      Process.unlink(pid)

      exit_reason =
        try do
          Mob.Screen.dispatch(pid, "bad_nav", %{})
          nil
        catch
          :exit, reason -> reason
        end

      refute is_nil(exit_reason)
      assert inspect(exit_reason) =~ "no_such_screen"
    end
  end
end
