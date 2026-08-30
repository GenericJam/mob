defmodule Mob.Nav.ResetAllTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :mob_reset_all_test, adapter: Ecto.Adapters.SQLite3
  end

  @create_table """
  CREATE TABLE IF NOT EXISTS mob_screen_states (
    key TEXT PRIMARY KEY NOT NULL,
    vsn INTEGER NOT NULL DEFAULT 0,
    data BLOB NOT NULL,
    updated_at INTEGER NOT NULL
  )
  """

  defmodule LoginScreen do
    use Mob.Screen

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :source, Map.get(params, :source))}

    def render(assigns),
      do: %{type: :text, props: %{text: "login #{assigns.source}"}, children: []}

    def handle_event("home_a", _, socket) do
      {:noreply, Mob.Socket.switch_tab(socket, :home, mount_params: %{session: :a})}
    end

    def handle_event("home_b", _, socket) do
      {:noreply, Mob.Socket.switch_tab(socket, :home, mount_params: %{session: :b})}
    end

    def handle_event("persistent_a", _, socket) do
      {:noreply, Mob.Socket.switch_tab(socket, :persistent, mount_params: %{session: :a})}
    end
  end

  defmodule HomeScreen do
    use Mob.Screen

    @detail Mob.Nav.ResetAllTest.HomeDetailScreen

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :session, Map.fetch!(params, :session))}

    def render(assigns),
      do: %{type: :text, props: %{text: "home #{assigns.session}"}, children: []}

    def handle_event("detail", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_event("settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings, mount_params: %{session: :a})}
  end

  defmodule PersistentHomeScreen do
    use Mob.Screen, vsn: 1

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :session, Map.fetch!(params, :session))}

    def render(assigns),
      do: %{type: :text, props: %{text: "persistent #{assigns.session}"}, children: []}

    def handle_event("settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings, mount_params: %{session: :a})}
  end

  defmodule HomeDetailScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home detail"}, children: []}

    def handle_event("settings", _, socket),
      do: {:noreply, Mob.Socket.switch_tab(socket, :settings, mount_params: %{session: :a})}
  end

  defmodule SettingsScreen do
    use Mob.Screen

    @detail Mob.Nav.ResetAllTest.SettingsDetailScreen

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, :session, Map.fetch!(params, :session))}

    def render(assigns),
      do: %{type: :text, props: %{text: "settings #{assigns.session}"}, children: []}

    def handle_event("detail", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @detail)}

    def handle_event("reset_home", _, socket) do
      {:noreply, Mob.Socket.reset_to(socket, HomeScreen, %{session: :b}, scope: :all)}
    end

    def handle_event("reset_persistent", _, socket) do
      {:noreply, Mob.Socket.reset_to(socket, PersistentHomeScreen, %{session: :b}, scope: :all)}
    end
  end

  defmodule SettingsDetailScreen do
    use Mob.Screen

    @login Mob.Nav.ResetAllTest.LoginScreen
    @broken Mob.Nav.ResetAllTest.BrokenScreen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "settings detail"}, children: []}

    def handle_event("logout", _, socket) do
      {:noreply, Mob.Socket.reset_to(socket, @login, %{source: :logout}, scope: :all)}
    end

    def handle_event("broken", _, socket) do
      {:noreply, Mob.Socket.reset_to(socket, @broken, %{}, scope: :all)}
    end
  end

  defmodule BrokenScreen do
    use Mob.Screen
    def mount(_params, _session, _socket), do: {:error, :broken}
    def render(_assigns), do: %{type: :text, props: %{text: "broken"}, children: []}
  end

  defmodule TabApp do
    @behaviour Mob.App
    import Mob.App

    @home Mob.Nav.ResetAllTest.HomeScreen
    @persistent Mob.Nav.ResetAllTest.PersistentHomeScreen
    @settings Mob.Nav.ResetAllTest.SettingsScreen

    def navigation(_) do
      tab_bar([
        stack(:home, root: @home, title: "Home"),
        stack(:persistent, root: @persistent, title: "Persistent"),
        stack(:settings, root: @settings, title: "Settings")
      ])
    end
  end

  defmodule OldNavWithoutReset do
  end

  defmodule OldScreenServerWithoutDiscard do
  end

  defmodule OldScreenStateWithoutDeleteAll do
  end

  setup do
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> stop_safely(pid)
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(TabApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, router} = Mob.Screen.start_link(LoginScreen, %{source: :initial})
    on_exit(fn -> stop_safely(router) end)

    %{router: router}
  end

  test "all-stack reset discards an orphan, both tab histories, and parked screens", %{
    router: router
  } do
    Mob.Screen.dispatch(router, "home_a", %{})
    Mob.Screen.dispatch(router, "detail", %{})
    Mob.Screen.dispatch(router, "settings", %{})
    Mob.Screen.dispatch(router, "detail", %{})

    before_reset = :sys.get_state(router)
    old_pids = Map.keys(before_reset.screens)
    assert length(old_pids) == 5

    Mob.Screen.dispatch(router, "logout", %{})

    state = :sys.get_state(router)
    assert state.current.module == LoginScreen
    assert state.current.params == %{source: :logout}
    assert state.nav.active == :__mob_root__
    assert state.nav.history == []
    assert state.nav.parked == %{}
    assert Map.keys(state.screens) == [state.current.pid]
    assert Enum.all?(old_pids, &(not Process.alive?(&1)))

    Mob.Screen.dispatch(router, "home_b", %{})

    assert Mob.Screen.get_current_module(router) == HomeScreen
    assert Mob.Screen.get_socket(router).assigns.session == :b
    refute Mob.Router.get_screen_pid(router) in old_pids
  end

  test "resetting to a declared root selects its stack", %{router: router} do
    Mob.Screen.dispatch(router, "home_a", %{})
    Mob.Screen.dispatch(router, "settings", %{})
    Mob.Screen.dispatch(router, "reset_home", %{})

    state = :sys.get_state(router)
    assert state.current.module == HomeScreen
    assert state.current.params == %{session: :b}
    assert state.nav.active == :home
    assert state.nav.history == []
    assert state.nav.parked == %{}
    assert state.nav.order == [:home, :persistent, :settings]
  end

  test "a failed replacement mount leaves every stack intact", %{router: router} do
    Mob.Screen.dispatch(router, "home_a", %{})
    Mob.Screen.dispatch(router, "detail", %{})
    Mob.Screen.dispatch(router, "settings", %{})
    Mob.Screen.dispatch(router, "detail", %{})

    before_reset = :sys.get_state(router)

    capture_log(fn -> Mob.Screen.dispatch(router, "broken", %{}) end)

    after_reset = :sys.get_state(router)
    assert after_reset.current == before_reset.current
    assert after_reset.nav == before_reset.nav
    assert after_reset.screens == before_reset.screens
    assert Enum.all?(Map.keys(before_reset.screens), &Process.alive?/1)
  end

  test "an all-stack reset is a persistence boundary between users", %{router: router} do
    db = System.tmp_dir!() <> "/mob_reset_all_#{System.unique_integer([:positive])}.db"
    Application.put_env(:mob_reset_all_test, TestRepo, database: db, pool_size: 1)
    Application.put_env(:mob, :repo, TestRepo)
    start_supervised!(TestRepo)
    TestRepo.query!(@create_table, [])

    on_exit(fn ->
      Application.delete_env(:mob, :repo)
      File.rm(db)
    end)

    Mob.Screen.dispatch(router, "persistent_a", %{})
    user_a_socket = Mob.Screen.get_socket(router)
    assert user_a_socket.assigns.session == :a
    Mob.ScreenState.dump(PersistentHomeScreen, user_a_socket)

    Mob.Screen.dispatch(router, "settings", %{})
    Mob.Screen.dispatch(router, "reset_persistent", %{})

    user_b_socket = Mob.Screen.get_socket(router)
    assert user_b_socket.assigns.session == :b
    assert :not_found = Mob.ScreenState.load(PersistentHomeScreen, user_b_socket)
    assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM mob_screen_states", [])

    # Keep this test's fixture from writing after its Repo is torn down. The
    # old user-A screen was already stopped by reset; this prepares only the
    # fresh user-B screen for the test process's own shutdown.
    current = Mob.Router.get_screen_pid(router)
    assert :ok = Mob.Screen.Server.discard_persisted_state(current)
  end

  test "new Router resets safely while an old Mob.Nav module is loaded" do
    home = %{module: HomeScreen, pid: self()}
    settings = %{module: SettingsScreen, pid: self()}

    nav = %Mob.Nav{
      active: :settings,
      history: [settings],
      parked: %{home: %{current: home, history: [home]}},
      order: [:home, :settings],
      roots: %{home: HomeScreen, settings: SettingsScreen}
    }

    reset = Mob.Router.reset_navigation(nav, HomeScreen, OldNavWithoutReset)

    assert reset.active == :home
    assert reset.history == []
    assert reset.parked == %{}
    assert reset.order == [:home, :settings]
    assert reset.roots == nav.roots
  end

  test "new Router recognises an old Screen.Server cannot safely reset all stacks" do
    refute Mob.Router.reset_all_supported?(OldScreenServerWithoutDiscard)
    assert Mob.Router.reset_all_supported?(Mob.Screen.Server)
  end

  test "new Router recognises an old ScreenState cannot safely reset all stacks" do
    refute Mob.Router.reset_all_supported?(
             Mob.Screen.Server,
             OldScreenStateWithoutDeleteAll
           )

    assert Mob.Router.reset_all_supported?(Mob.Screen.Server, Mob.ScreenState)
  end

  test "capability detection loads an available ScreenState on a cold path" do
    :code.purge(Mob.ScreenState)
    :code.delete(Mob.ScreenState)
    assert :code.is_loaded(Mob.ScreenState) == false

    assert Mob.Router.reset_all_supported?(Mob.Screen.Server, Mob.ScreenState)
    refute :code.is_loaded(Mob.ScreenState) == false
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
