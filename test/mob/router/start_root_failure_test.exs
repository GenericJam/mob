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
end
