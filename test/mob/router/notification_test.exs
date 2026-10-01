defmodule Mob.Router.NotificationTest do
  # start_root registers :mob_screen and the singleton render services.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Test.ProcessHelpers

  # Reports every {:notification, _} it receives to the test process named in
  # its params, tagged with its own pid. With `live_during_mount: json` it
  # hands the router that envelope while mounting, as native would for a
  # notification arriving while the root screen mounts.
  defmodule HomeScreen do
    use Mob.Screen

    def mount(%{test: test} = params, _session, socket) do
      if json = params[:live_during_mount], do: send(:mob_screen, {:mob_notification, json, nil})
      {:ok, Mob.Socket.assign(socket, :test, test)}
    end

    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_info({:notification, notification}, socket) do
      send(socket.assigns.test, {:screen_got, self(), notification})
      {:noreply, socket}
    end
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: Mob.Router.NotificationTest.HomeScreen)
  end

  # The native store as the router sees it: a FIFO, one envelope per take.
  defmodule StubNif do
    @slot {__MODULE__, :slot}

    def reset, do: :persistent_term.put(@slot, [])
    def store(json), do: :persistent_term.put(@slot, :persistent_term.get(@slot, []) ++ [json])

    def take_launch_notification do
      case :persistent_term.get(@slot, []) do
        [] ->
          :none

        [json | rest] ->
          :persistent_term.put(@slot, rest)
          json
      end
    end

    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def clear_taps, do: :ok
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def set_root(_json), do: :ok
  end

  @tap ~s({"id":"n1","title":"Hi","body":"There","source":"local","presentation":"tap","action":"default","data":{"thread_id":"42"}})
  @arrival ~s({"id":"n2","source":"push","presentation":"foreground","data":{}})

  setup do
    ProcessHelpers.stop_if_running(Mob.Nav.Registry)
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    StubNif.reset()

    on_exit(fn ->
      StubNif.reset()
      ProcessHelpers.stop_pid(registry)
    end)

    :ok
  end

  defp start_router do
    {:ok, router} = Mob.Router.start_link(HomeScreen, %{test: self()}, nif: StubNif)
    on_exit(fn -> ProcessHelpers.stop_pid(router) end)
    {router, Mob.Screen.get_screen_pid(router)}
  end

  describe "{:mob_notification, json, target}" do
    test "with no target, the decoded notification goes to the current screen" do
      {router, screen} = start_router()

      send(router, {:mob_notification, @arrival, nil})

      assert_receive {:screen_got, ^screen,
                      %{id: "n2", source: :push, presentation: :foreground, action: nil}}
    end

    # MOB-316: Android sent the raw JSON straight to the registered pid, which
    # only the router knew how to decode, so a screen dropped the tap.
    test "a live registered target gets the decoded notification instead" do
      {router, _screen} = start_router()

      send(router, {:mob_notification, @tap, self()})

      assert_receive {:notification,
                      %{
                        id: "n1",
                        title: "Hi",
                        body: "There",
                        presentation: :tap,
                        action: "default",
                        data: %{thread_id: "42"}
                      }}

      refute_receive {:screen_got, _, _}, 50
    end

    test "a dead registered target falls back to the current screen" do
      {router, screen} = start_router()
      dead = spawn(fn -> :ok end)
      ProcessHelpers.await_exit(dead)

      send(router, {:mob_notification, @tap, dead})

      assert_receive {:screen_got, ^screen, %{id: "n1", presentation: :tap}}
    end

    test "an undecodable payload is logged and dropped, and the router survives" do
      {router, screen} = start_router()

      log =
        capture_log(fn ->
          send(router, {:mob_notification, "{not json", nil})
          :sys.get_state(router)
        end)

      assert log =~ "dropped a notification that could not be decoded: invalid_json"
      refute_receive {:screen_got, _, _}, 50

      send(router, {:mob_notification, @arrival, nil})
      assert_receive {:screen_got, ^screen, %{id: "n2"}}
    end
  end

  describe ":mob_notification_stored" do
    # Native stored the envelope because the router was not registered when it
    # looked, then saw it registered. The router takes the slot; a second poke
    # finds it empty, so the notification arrives once.
    test "takes the stored notification exactly once" do
      {router, screen} = start_router()
      StubNif.store(@tap)

      send(router, :mob_notification_stored)
      send(router, :mob_notification_stored)

      assert_receive {:screen_got, ^screen, %{id: "n1", presentation: :tap}}
      refute_receive {:screen_got, _, _}, 50
      assert StubNif.take_launch_notification() == :none
    end

    # The sender that stored has not poked the router yet when a live send
    # arrives; the stored envelope came first, so it is delivered first, and
    # the late poke finds nothing.
    test "a stored notification is not overtaken by a live one" do
      {router, _screen} = start_router()
      StubNif.store(@tap)

      send(router, {:mob_notification, @arrival, nil})
      send(router, :mob_notification_stored)

      assert ids_received(2) == ["n1", "n2"]
      refute_receive {:screen_got, _, _}, 50
    end
  end

  describe "a notification stored before the router started" do
    setup do
      ProcessHelpers.ensure_component_registry()
      :ok
    end

    # MOB-178: the tap that cold-launches the app is stored before the BEAM is
    # up; the root screen must get it once it has mounted. Envelopes from older
    # Android shells carry no presentation, which means a tap.
    test "is delivered once to the root screen after it mounts" do
      StubNif.store(~s({"id":"cold","source":"local","data":{"screen":"inbox"}}))

      {:ok, router} = Mob.Router.start_root(HomeScreen, %{test: self()}, nif: StubNif)
      on_exit(fn -> ProcessHelpers.stop_root(router) end)
      screen = Mob.Screen.get_screen_pid(router)

      assert_receive {:screen_got, ^screen,
                      %{
                        id: "cold",
                        presentation: :tap,
                        action: "default",
                        data: %{screen: "inbox"}
                      }}

      send(router, :mob_notification_stored)
      refute_receive {:screen_got, _, _}, 50
    end

    # A foreground arrival during boot must not displace the launching tap.
    test "delivers every stored notification, oldest first" do
      StubNif.store(@tap)
      StubNif.store(@arrival)

      {:ok, router} = Mob.Router.start_root(HomeScreen, %{test: self()}, nif: StubNif)
      on_exit(fn -> ProcessHelpers.stop_root(router) end)

      assert ids_received(2) == ["n1", "n2"]
      refute_receive {:screen_got, _, _}, 50
    end

    # A notification sent live while the root screen mounts came in after the
    # stored ones, so it must not overtake them.
    test "delivers stored notifications before one sent while the root mounts" do
      StubNif.store(@tap)

      {:ok, router} =
        Mob.Router.start_root(HomeScreen, %{test: self(), live_during_mount: @arrival},
          nif: StubNif
        )

      on_exit(fn -> ProcessHelpers.stop_root(router) end)

      assert ids_received(2) == ["n1", "n2"]
      refute_receive {:screen_got, _, _}, 50
    end
  end

  # The ids of the next `count` notifications the screen reported, in arrival
  # order (no selective receive, so a reordering shows).
  defp ids_received(count) do
    for _ <- 1..count do
      assert_receive {:screen_got, _screen, notification}
      notification.id
    end
  end
end
