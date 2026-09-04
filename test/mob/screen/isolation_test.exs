defmodule Mob.Screen.IsolationTest do
  @moduledoc """
  The crash isolation `Mob.Screen`'s moduledoc claimed for a long time and
  mob#76 had to write around.

  Before MOB-112 every screen shared one process, so a crash in any
  `handle_event` took navigation and every other screen with it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.Screen.IsolationTest.DetailScreen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :count, 0)}
    def render(assigns), do: %{type: :text, props: %{text: "home #{assigns.count}"}, children: []}

    def handle_event("bump", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}

    def handle_event("boom", _, _socket), do: raise("screen exploded")

    def handle_event("push", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_info(:who_am_i, socket),
      do: {:noreply, Mob.Socket.assign(socket, :seen_self, self())}

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  defmodule DetailScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :where, :detail)}
    def render(assigns), do: %{type: :text, props: %{text: "#{assigns.where}"}, children: []}

    def handle_event("boom", _, _socket), do: raise("detail exploded")
    def handle_event("back", _, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Screen.IsolationTest.HomeScreen
    def navigation(_), do: stack(:home, root: @home)
  end

  defp history_pids(owner) do
    owner |> :sys.get_state() |> Map.fetch!(:nav) |> Mob.Nav.history() |> Enum.map(& &1.pid)
  end

  setup do
    Mob.Test.ProcessHelpers.stop_if_running(Mob.Nav.Registry)

    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, owner} = Mob.Screen.start_link(HomeScreen, %{})
    on_exit(fn -> stop_safely(owner) end)

    %{owner: owner}
  end

  # `if Process.alive?, do: GenServer.stop` races: the process can exit between
  # the check and the stop, and the :noproc exit then fails the test from inside
  # the on_exit runner. Screens and their owner die with the test process.
  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "one process per screen" do
    test "the owner and the screen are different processes", %{owner: owner} do
      assert Mob.Screen.get_screen_pid(owner) != owner
    end

    test "self() inside a callback is the screen's own pid", %{owner: owner} do
      # What user code already assumed when writing on_tap: {self(), :tag} or
      # starting a task. Before MOB-112 this was the one shared process, which
      # is what let screen A's task result land in screen B (MOB-107).
      screen = Mob.Screen.get_screen_pid(owner)
      send(screen, :who_am_i)
      :sys.get_state(screen)

      assert Mob.Screen.get_socket(owner).assigns.seen_self == screen
    end

    test "pushing starts a second screen process and keeps the first", %{owner: owner} do
      first = Mob.Screen.get_screen_pid(owner)
      Mob.Screen.dispatch(owner, "push", %{})
      second = Mob.Screen.get_screen_pid(owner)

      assert second != first
      assert Process.alive?(first), "the screen below stays resident so pop restores it"
    end
  end

  describe "crash isolation" do
    test "a crashing handle_event does not take down the owner", %{owner: owner} do
      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)
      assert Process.alive?(owner)
    end

    test "navigation survives a crash", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)

      assert length(Mob.Screen.get_nav_history(owner)) == 1
    end

    test "a sibling screen survives a crash", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      [home_pid] = history_pids(owner)

      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)

      assert Process.alive?(home_pid), "the screen below the crash is untouched"
    end

    test "the owner restarts the crashed screen", %{owner: owner} do
      before = Mob.Screen.get_screen_pid(owner)
      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)
      :sys.get_state(owner)

      after_crash = Mob.Screen.get_screen_pid(owner)
      assert after_crash != before
      assert Process.alive?(after_crash)
      assert Mob.Screen.get_current_module(owner) == HomeScreen
    end

    test "a restarted screen re-mounts and loses its assigns", %{owner: owner} do
      Mob.Screen.dispatch(owner, "bump", %{})
      assert Mob.Screen.get_socket(owner).assigns.count == 1

      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)
      :sys.get_state(owner)

      # mount/3 ran again. Documented, not incidental.
      assert Mob.Screen.get_socket(owner).assigns.count == 0
    end

    test "the restart is logged, since losing assigns is visible to users", %{owner: owner} do
      log =
        capture_log(fn ->
          Mob.Screen.dispatch(owner, "boom", %{})
          # The restart happens when the :DOWN lands, after dispatch returns.
          :sys.get_state(owner)
        end)

      assert log =~ "crashed and is being restarted"
    end

    test "the screen still works after being restarted", %{owner: owner} do
      capture_log(fn -> Mob.Screen.dispatch(owner, "boom", %{}) end)
      :sys.get_state(owner)

      Mob.Screen.dispatch(owner, "bump", %{})
      assert Mob.Screen.get_socket(owner).assigns.count == 1
    end
  end

  describe "screen lifecycle" do
    test "popping stops the screen that leaves the stack", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)
      ref = Process.monitor(detail)

      Mob.Screen.dispatch(owner, "back", %{})

      assert_receive {:DOWN, ^ref, :process, ^detail, _}
      assert Mob.Screen.get_current_module(owner) == HomeScreen
    end

    test "a popped screen is not restarted", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)
      Mob.Screen.dispatch(owner, "back", %{})
      :sys.get_state(owner)

      refute Process.alive?(detail)
      assert Mob.Screen.get_current_module(owner) == HomeScreen
      assert Mob.Screen.get_nav_history(owner) == []
    end

    test "stopping the owner stops its screens", %{owner: owner} do
      Mob.Screen.dispatch(owner, "push", %{})
      detail = Mob.Screen.get_screen_pid(owner)
      ref = Process.monitor(detail)

      GenServer.stop(owner)
      assert_receive {:DOWN, ^ref, :process, ^detail, _}
    end
  end
end
