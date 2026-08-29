defmodule Mob.Screen.MigrationTest do
  @moduledoc """
  The surface that was coupled to there being one screen process.

  Hot reload had to become a broadcast, and `dump_state`/`load_state` had to
  span processes — a screen parked under an inactive tab holds its own socket
  now, so only that process can persist it. Both fell out of MOB-112, and
  neither had a test.
  """
  use ExUnit.Case, async: false

  # ── Hot reload ────────────────────────────────────────────────────────────

  defmodule Renders do
    def start, do: Agent.start(fn -> %{} end, name: __MODULE__)
    def count(module), do: Agent.get(__MODULE__, &Map.get(&1, module, 0))
    def note(module), do: Agent.update(__MODULE__, &Map.update(&1, module, 1, fn n -> n + 1 end))
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

  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.Screen.MigrationTest.DetailScreen

    def mount(_p, _s, socket), do: {:ok, socket}

    def render(_assigns) do
      Mob.Screen.MigrationTest.Renders.note(__MODULE__)
      %{type: :text, props: %{text: "home"}, children: []}
    end

    def handle_event("push", _, socket), do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule DetailScreen do
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}

    def render(_assigns) do
      Mob.Screen.MigrationTest.Renders.note(__MODULE__)
      %{type: :text, props: %{text: "detail"}, children: []}
    end

    def handle_event("to_settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings)}
  end

  defmodule SettingsScreen do
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}

    def render(_assigns) do
      Mob.Screen.MigrationTest.Renders.note(__MODULE__)
      %{type: :text, props: %{text: "settings"}, children: []}
    end

    def handle_event("to_home", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :home)}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Screen.MigrationTest.HomeScreen
    @settings Mob.Screen.MigrationTest.SettingsScreen
    def navigation(_), do: tab_bar([stack(:home, root: @home), stack(:settings, root: @settings)])
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # Screens dump in their own terminate/2, which runs after the router exits —
  # so the router being down does not mean the writes have landed.
  defp stop_and_await_screens(router) do
    refs = for pid <- live_screen_pids(router), do: {pid, Process.monitor(pid)}
    stop_safely(router)

    for {pid, ref} <- refs do
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> flunk("screen #{inspect(pid)} did not terminate")
      end
    end
  end

  # Every live screen: current, the active stack's history, and everything
  # parked under an inactive stack.
  defp live_screen_pids(router) do
    state = :sys.get_state(router)

    parked =
      state.nav
      |> Map.get(:parked, %{})
      |> Enum.flat_map(fn {_name, %{current: c, history: h}} -> [c | h] end)

    ([state.current] ++ Mob.Nav.history(state.nav) ++ parked)
    |> Enum.map(& &1.pid)
    |> Enum.uniq()
  end

  # Hot reload is a broadcast of casts, and a screen's render/1 is user code
  # that may take as long as it likes. Draining each screen covers the common
  # case; this covers the rest without pinning the test to how fast render/1 is.
  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(5) && do_wait_until(fun, deadline)
    end
  end

  defp reset_services do
    for name <- [Mob.Sender, Mob.Listener, Mob.ComponentRegistry, Mob.Nav.Registry],
        pid = Process.whereis(name),
        do: stop_safely(pid)
  end

  describe "hot reload reaches every live screen" do
    setup do
      reset_services()

      if pid = Process.whereis(Renders), do: Agent.stop(pid)
      {:ok, renders} = Renders.start()
      # Globally named and unlinked, so it outlives the suite unless stopped.
      on_exit(fn -> if Process.alive?(renders), do: Agent.stop(renders) end)

      {:ok, _} = Mob.ComponentRegistry.start_link()
      {:ok, _} = Mob.Nav.Registry.start_link(TabApp)
      {:ok, router} = Mob.Router.start_root(HomeScreen, %{}, nif: StubNif)

      on_exit(fn ->
        stop_safely(router)
        reset_services()
      end)

      %{router: router}
    end

    test "a screen in history and one parked under another tab both repaint", %{router: router} do
      # all_entries/1 has three branches — current, the ACTIVE stack's history,
      # and everything parked — so the scenario has to populate all three or a
      # deleted branch goes unnoticed. Push, switch away (parking the home stack
      # and mounting settings), then switch back: home is active with Detail
      # current and Home in its history, and the settings stack is parked.
      modules = [HomeScreen, DetailScreen, SettingsScreen]

      Mob.Screen.dispatch(router, "push", %{})
      Mob.Screen.dispatch(router, "to_settings", %{})
      Mob.Screen.dispatch(router, "to_home", %{})

      # Every first paint is an async cast, so settle those before taking the
      # baseline or it races the mount renders.
      assert wait_until(fn -> Enum.all?(modules, &(Renders.count(&1) > 0)) end) == :ok
      before = for m <- modules, into: %{}, do: {m, Renders.count(m)}

      screens = live_screen_pids(router)
      assert length(screens) == 3

      state = :sys.get_state(router)
      assert state.current.module == DetailScreen

      assert [%{module: HomeScreen}] = Mob.Nav.history(state.nav),
             "active history must be populated"

      assert Map.has_key?(state.nav.parked, :settings), "a parked stack must be populated"

      GenServer.cast(router, :__mob_hot_reload__)

      # Neither :sys.get_state(router) nor Mob.Sender.sync/1 is a barrier here.
      # hot_reload/1 is a cast per screen, so draining the router proves only
      # that the casts were sent; and a background screen's tree is dropped
      # rather than committed, so the sender catching up says nothing either.
      # Drain the screens, then wait — render/1 is user code and may be slow.
      :sys.get_state(router)
      Enum.each(screens, &:sys.get_state/1)

      assert wait_until(fn -> Enum.all?(modules, &(Renders.count(&1) > before[&1])) end) == :ok,
             "not every live screen repainted on hot reload: " <>
               inspect(for m <- modules, into: %{}, do: {m, {before[m], Renders.count(m)}})
    end
  end

  # ── State restore across processes ────────────────────────────────────────

  defmodule Repo do
    use Ecto.Repo, otp_app: :mob_migration_test, adapter: Ecto.Adapters.SQLite3
  end

  @create_table """
  CREATE TABLE IF NOT EXISTS mob_screen_states (
    key      TEXT    PRIMARY KEY NOT NULL,
    vsn      INTEGER NOT NULL DEFAULT 0,
    data     BLOB    NOT NULL,
    updated_at INTEGER NOT NULL
  )
  """

  defmodule PersistHome do
    use Mob.Screen, vsn: 1
    @detail Mob.Screen.MigrationTest.PersistDetail

    def mount(_p, _s, socket), do: {:ok, Mob.Socket.assign(socket, :note, "home-default")}
    def render(_a), do: %{type: :text, props: %{text: "h"}, children: []}

    def handle_event("mark", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :note, "home-kept")}

    def handle_event("push", _, socket), do: {:noreply, Mob.Socket.push_screen(socket, @detail)}
  end

  defmodule PersistDetail do
    use Mob.Screen, vsn: 1
    def mount(_p, _s, socket), do: {:ok, Mob.Socket.assign(socket, :note, "detail-default")}
    def render(_a), do: %{type: :text, props: %{text: "d"}, children: []}

    def handle_event("mark", _, socket),
      do: {:noreply, Mob.Socket.assign(socket, :note, "detail-kept")}
  end

  defmodule PersistApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Screen.MigrationTest.PersistHome
    def navigation(_), do: stack(:home, root: @home)
  end

  describe "state restore spans every live screen's process" do
    setup do
      reset_services()
      db = System.tmp_dir!() <> "/mob_migration_#{System.unique_integer([:positive])}.db"
      Application.put_env(:mob_migration_test, Repo, database: db, pool_size: 1)
      Application.put_env(:mob, :repo, Repo)

      start_supervised!(Repo)
      Repo.query!(@create_table, [])

      {:ok, _} = Mob.Nav.Registry.start_link(PersistApp)

      on_exit(fn ->
        Application.delete_env(:mob, :repo)
        Application.delete_env(:mob_migration_test, Repo)
        reset_services()
        File.rm(db)
      end)

      :ok
    end

    test "a screen in history persists too, not just the one on screen" do
      # Before MOB-112 only the active screen held a socket, so only it could
      # ever be dumped — a screen you had navigated away from lost its state.
      {:ok, router} = Mob.Screen.start_link(PersistHome, %{})
      Mob.Screen.dispatch(router, "mark", %{})
      Mob.Screen.dispatch(router, "push", %{})
      Mob.Screen.dispatch(router, "mark", %{})

      stop_and_await_screens(router)

      %{rows: rows} = Repo.query!("SELECT key FROM mob_screen_states", [])
      keys = List.flatten(rows)

      assert to_string(PersistHome) in keys, "the screen in history was never dumped"
      assert to_string(PersistDetail) in keys
    end

    test "both screens restore their own assigns on relaunch" do
      {:ok, router} = Mob.Screen.start_link(PersistHome, %{})
      Mob.Screen.dispatch(router, "mark", %{})
      Mob.Screen.dispatch(router, "push", %{})
      Mob.Screen.dispatch(router, "mark", %{})
      stop_and_await_screens(router)

      # Relaunch: mount runs again, then load_state/2 puts the dumped assigns back.
      {:ok, router} = Mob.Screen.start_link(PersistHome, %{})

      assert Mob.Screen.get_socket(router).assigns.note == "home-kept"

      Mob.Screen.dispatch(router, "push", %{})
      assert Mob.Screen.get_socket(router).assigns.note == "detail-kept"

      # Await the screens, not just the router: they dump in their own
      # terminate/2, which runs after the router exits. start_supervised!(Repo)
      # is torn down before on_exit, so an unawaited dump writes into a closed
      # connection and logs an error out of a passing test.
      stop_and_await_screens(router)
    end
  end
end
