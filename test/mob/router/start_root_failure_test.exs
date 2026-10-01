defmodule Mob.Router.StartRootFailureTest do
  # Registers :mob_screen and the singleton render services: not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule RaisingMountScreen do
    use Mob.Screen
    def mount(_params, _session, _socket), do: raise("delivered mount bug")
    def render(_assigns), do: %{type: :text, props: %{text: "never"}, children: []}
  end

  defmodule RefusingMountScreen do
    use Mob.Screen
    def mount(_params, _session, _socket), do: {:error, :no_session}
    def render(_assigns), do: %{type: :text, props: %{text: "never"}, children: []}
  end

  # Mounts, then raises in render until `:failures_left` reaches 0.
  defmodule RaisingRenderScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      case :persistent_term.get({__MODULE__, :failures_left}, :infinity) do
        0 ->
          %{type: :text, props: %{text: "recovered"}, children: []}

        :infinity ->
          raise "delivered render bug"

        n ->
          :persistent_term.put({__MODULE__, :failures_left}, n - 1)
          raise "delivered render bug"
      end
    end
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: Mob.Router.StartRootFailureTest.RaisingMountScreen)
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
    services = [Mob.Sender, Mob.Listener]

    on_exit(fn ->
      Mob.Test.ProcessHelpers.stop_all(Enum.map(services, &Process.whereis/1))
      Mob.Test.ProcessHelpers.stop_pid(registry)
    end)

    Process.flag(:trap_exit, true)
    :ok
  end

  # Without this, a root screen that can't start leaves a black screen and
  # nothing in logcat: init failures produce no crash log of their own.
  test "a root screen whose mount raises is logged with the exception" do
    log =
      capture_log(fn ->
        assert {:error, _} = Mob.Screen.start_root(RaisingMountScreen, %{}, nif: StubNif)
      end)

    assert log =~
             "[mob] root screen Mob.Router.StartRootFailureTest.RaisingMountScreen failed to start"

    assert log =~ "delivered mount bug"
  end

  test "a root screen whose mount returns an error is logged with the reason" do
    log =
      capture_log(fn ->
        assert {:error, :no_session} =
                 Mob.Screen.start_root(RefusingMountScreen, %{}, nif: StubNif)
      end)

    assert log =~
             "[mob] root screen Mob.Router.StartRootFailureTest.RefusingMountScreen failed to start"

    assert log =~ ":no_session"
  end

  describe "when no live screen is left" do
    setup do
      Mob.Test.ProcessHelpers.stop_if_running(Mob.ComponentRegistry)
      {:ok, registry} = Mob.ComponentRegistry.start_link()

      on_exit(fn ->
        :persistent_term.erase({RaisingRenderScreen, :failures_left})
        Mob.Test.ProcessHelpers.stop_pid(registry)
      end)

      test_pid = self()
      %{on_no_live_screen: fn module -> send(test_pid, {:no_live_screen, module}) end}
    end

    # A blank process that stays up is brought back by the next launch, so a
    # device relaunch never boots fresh; the router ends it instead.
    test "a root screen whose render always raises ends the app, after saying why", %{
      on_no_live_screen: action
    } do
      log =
        capture_log(fn ->
          {:ok, router} =
            Mob.Screen.start_root(RaisingRenderScreen, %{},
              nif: StubNif,
              on_no_live_screen: action
            )

          assert_receive {:no_live_screen, RaisingRenderScreen}, 2_000
          Mob.Test.ProcessHelpers.stop_pid(router)
        end)

      assert log =~
               "[mob] ending the app process so the next launch starts fresh " <>
                 "(no live screen after Mob.Router.StartRootFailureTest.RaisingRenderScreen " <>
                 "could not be restarted)"

      refute_received {:no_live_screen, _}
    end

    @tag :capture_log
    test "a screen that recovers within the restart limit keeps the app running", %{
      on_no_live_screen: action
    } do
      :persistent_term.put({RaisingRenderScreen, :failures_left}, 3)

      {:ok, router} =
        Mob.Screen.start_root(RaisingRenderScreen, %{}, nif: StubNif, on_no_live_screen: action)

      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(router) end)

      refute_receive {:no_live_screen, _}, 300
      assert Mob.Router.get_current_module(router) == RaisingRenderScreen
    end

    # A root that fails in mount never had a screen at all: the same blank
    # process a launcher relaunch would bring back.
    test "a root screen whose mount fails ends the app, after saying why", %{
      on_no_live_screen: action
    } do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   Mob.Screen.start_root(RaisingMountScreen, %{},
                     nif: StubNif,
                     on_no_live_screen: action
                   )
        end)

      assert_received {:no_live_screen, RaisingMountScreen}

      assert log =~
               "[mob] ending the app process so the next launch starts fresh " <>
                 "(root screen Mob.Router.StartRootFailureTest.RaisingMountScreen failed to start)"
    end

    @tag :capture_log
    test "a failed start doesn't end the app while another root screen is live", %{
      on_no_live_screen: action
    } do
      :persistent_term.put({RaisingRenderScreen, :failures_left}, 0)
      {:ok, live} = Mob.Screen.start_root(RaisingRenderScreen, %{}, nif: StubNif)
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(live) end)

      assert {:error, _} =
               Mob.Screen.start_root(RefusingMountScreen, %{},
                 nif: StubNif,
                 on_no_live_screen: action
               )

      refute_received {:no_live_screen, _}
      assert Process.alive?(live)
    end
  end
end
