defmodule Mob.Screen.RestartTest do
  @moduledoc """
  Restarting a screen that is *not* the one on screen.

  The first cut of MOB-112 restarted every screen with `%{}` params and the
  *active* stack's render ref. Both are wrong for a background screen: a screen
  that mounts on `%{id: id}` cannot come back from `%{}`, and a parked screen
  tagged with the active ref paints over the foreground tab the next time it
  re-renders.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.Screen.RestartTest.DetailScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :where, :home)}
    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.where}"}, children: []}

    def handle_event("push", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail, %{id: 42})}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule DetailScreen do
    use Mob.Screen

    # Mounts on a required param. A restart that forgets it cannot come back.
    def mount(%{id: id}, _session, socket), do: {:ok, Mob.Socket.assign(socket, :id, id)}
    def render(assigns), do: %{type: :text, props: %{text: "detail #{assigns.id}"}, children: []}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :where, :settings)}
    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.where}"}, children: []}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App

    @home Mob.Screen.RestartTest.HomeScreen
    @settings Mob.Screen.RestartTest.SettingsScreen

    def navigation(_) do
      tab_bar([stack(:home, root: @home), stack(:settings, root: @settings)])
    end
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp owner_state(owner), do: :sys.get_state(owner)
  defp history(owner), do: owner |> owner_state() |> Map.fetch!(:nav) |> Mob.Nav.history()
  defp parked(owner), do: owner |> owner_state() |> Map.fetch!(:nav) |> Map.fetch!(:parked)

  defp kill_and_settle(owner, pid) do
    capture_log(fn ->
      Process.exit(pid, :kill)
      # Let the owner process the EXIT and finish the restart.
      :sys.get_state(owner)
      :sys.get_state(owner)
    end)
  end

  setup do
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(TabApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, owner} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> stop_safely(owner) end)

    %{owner: owner}
  end

  describe "a screen in the active stack's history" do
    test "is restarted rather than left as a corpse", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      [home] = history(owner)

      kill_and_settle(owner, home.pid)

      [restarted] = history(owner)
      assert restarted.pid != home.pid
      assert Process.alive?(restarted.pid)
      assert restarted.module == HomeScreen
    end

    test "the screen on top is untouched", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)
      [home] = history(owner)

      kill_and_settle(owner, home.pid)

      assert Mob.Screen.get_screen_pid(owner) == detail
      assert Mob.Screen.get_current_module(owner) == DetailScreen
    end

    test "popping back reaches the restarted screen, not the dead one", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      [home] = history(owner)
      kill_and_settle(owner, home.pid)

      :ok = GenServer.call(owner, {:navigate, {:pop}})

      assert Mob.Screen.get_current_module(owner) == HomeScreen
      assert Mob.Screen.get_socket(owner).assigns.where == :home
      assert Mob.Screen.get_nav_history(owner) == []
    end
  end

  describe "restart reproduces the screen" do
    test "a screen that mounts on params comes back with them", %{owner: owner} do
      # Restarting with %{} would raise FunctionClauseError in mount/3 and the
      # screen would never return.
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)
      assert Mob.Screen.get_socket(owner).assigns.id == 42

      kill_and_settle(owner, detail)

      assert Mob.Screen.get_screen_pid(owner) != detail
      assert Mob.Screen.get_current_module(owner) == DetailScreen
      assert Mob.Screen.get_socket(owner).assigns.id == 42
    end
  end

  describe "a parked screen under an inactive stack" do
    test "stays alive across a tab switch", %{owner: owner} do
      home = Mob.Screen.get_screen_pid(owner)
      Mob.Screen.dispatch(owner, "to_settings", %{})

      assert Process.alive?(home)
      assert Mob.Screen.get_current_module(owner) == SettingsScreen
    end

    test "keeps its own render ref across a restart, and it is never the active one", %{
      owner: owner
    } do
      home = Mob.Screen.get_screen_pid(owner)
      home_ref = :sys.get_state(home).ref

      Mob.Screen.dispatch(owner, "to_settings", %{})
      settings_ref = :sys.get_state(owner).current.ref
      refute settings_ref == home_ref

      kill_and_settle(owner, home)

      restarted = parked(owner)[:home].current
      assert restarted.pid != home
      # The ref survives the restart — it is the same logical screen — and is
      # still not the active one, so a repaint from it is dropped rather than
      # committed over the foreground tab.
      assert restarted.ref == home_ref
      assert :sys.get_state(restarted.pid).ref == home_ref
      refute restarted.ref == :sys.get_state(owner).current.ref
    end

    test "switching back reaches the restarted screen", %{owner: owner} do
      home = Mob.Screen.get_screen_pid(owner)
      Mob.Screen.dispatch(owner, "to_settings", %{})
      kill_and_settle(owner, home)

      Mob.Screen.dispatch(owner, "to_home", %{})

      assert Mob.Screen.get_current_module(owner) == HomeScreen
      assert Mob.Screen.get_screen_pid(owner) != home
      assert Process.alive?(Mob.Screen.get_screen_pid(owner))
    end
  end

  describe "restart ceiling" do
    test "a screen that keeps crashing is given up on rather than looped", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})

      log =
        capture_log(fn ->
          # One more than the ceiling. Without it this spins at thousands of
          # restarts a second, each writing a log line.
          for _ <- 1..7 do
            pid = Mob.Screen.get_screen_pid(owner)
            Process.exit(pid, :kill)
            :sys.get_state(owner)
            :sys.get_state(owner)
          end
        end)

      assert log =~ "given up on rather than restarted in a loop"
    end

    test "giving up falls back to the screen beneath", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})

      capture_log(fn ->
        for _ <- 1..7 do
          pid = Mob.Screen.get_screen_pid(owner)
          Process.exit(pid, :kill)
          :sys.get_state(owner)
          :sys.get_state(owner)
        end
      end)

      assert Mob.Screen.get_current_module(owner) == HomeScreen
      assert Process.alive?(Mob.Screen.get_screen_pid(owner))
    end
  end

  describe "inspection is not a way to kill the app" do
    defmodule BadRenderScreen do
      use Mob.Screen
      def mount(_p, _s, socket), do: {:ok, socket}
      def render(_assigns), do: raise("render exploded")
    end

    test "a screen whose render/1 raises does not take the owner down", %{owner: owner} do
      :ok = GenServer.call(owner, {:navigate, {:reset, BadRenderScreen, %{}}})

      log = capture_log(fn -> assert GenServer.call(owner, :inspect).tree == nil end)

      assert Process.alive?(owner), "render/1 must run in the screen, not the owner"
      assert log =~ "render exploded"
    end
  end

  describe "bookkeeping" do
    test "a restarted screen is monitored exactly once", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      [home] = history(owner)
      kill_and_settle(owner, home.pid)

      [restarted] = history(owner)
      links = owner |> Process.info(:links) |> elem(1)
      assert Enum.count(links, &(&1 == restarted.pid)) == 1
    end

    test "a deliberately popped screen is not restarted", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)

      :ok = GenServer.call(owner, {:navigate, {:pop}})
      :sys.get_state(owner)

      refute Process.alive?(detail)
      assert Mob.Screen.get_current_module(owner) == HomeScreen
      assert Mob.Screen.get_nav_history(owner) == []
    end
  end
end
