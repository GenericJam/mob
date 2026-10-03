defmodule Mob.Router.LinkTest do
  # start_root registers :mob_screen and the singleton render services, and
  # Mob.Link's registration is global.
  use ExUnit.Case, async: false

  alias Mob.Test.ProcessHelpers

  # Reports every {:link, _} it receives to the test process named in its
  # params, tagged with its own pid. With `live_during_mount: url` it hands
  # the router that link while mounting, as native would for a link opened
  # while the root screen mounts.
  defmodule HomeScreen do
    use Mob.Screen

    def mount(%{test: test} = params, _session, socket) do
      if url = params[:live_during_mount], do: send(:mob_screen, {:mob_link, url})
      {:ok, Mob.Socket.assign(socket, :test, test)}
    end

    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_info({:link, link}, socket) do
      send(socket.assigns.test, {:screen_got, self(), link})
      {:noreply, socket}
    end
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: Mob.Router.LinkTest.HomeScreen)
  end

  # The native link store as the router sees it: a FIFO, one URL per take.
  defmodule StubNif do
    @slot {__MODULE__, :slot}

    def reset, do: :persistent_term.put(@slot, [])
    def store(url), do: :persistent_term.put(@slot, :persistent_term.get(@slot, []) ++ [url])

    def take_launch_link do
      case :persistent_term.get(@slot, []) do
        [] ->
          :none

        [url | rest] ->
          :persistent_term.put(@slot, rest)
          url
      end
    end

    def take_launch_notification, do: :none
    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def clear_taps, do: :ok
    def set_transition(_), do: :ok
    def register_tap(_), do: 0
    def set_root(_json), do: :ok
  end

  @launch "myapp://thread?id=42"
  @later "myapp://inbox"

  setup do
    ProcessHelpers.stop_if_running(Mob.Nav.Registry)
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    ProcessHelpers.ensure_component_registry()
    StubNif.reset()
    Mob.Link.unregister()

    on_exit(fn ->
      Mob.Link.unregister()
      StubNif.reset()
      ProcessHelpers.stop_pid(registry)
    end)

    :ok
  end

  defp start_root(params \\ %{}) do
    {:ok, router} =
      Mob.Router.start_root(HomeScreen, Map.put(params, :test, self()), nif: StubNif)

    on_exit(fn -> ProcessHelpers.stop_root(router) end)
    {router, Mob.Screen.get_screen_pid(router)}
  end

  describe "a link opened while the app runs ({:mob_link, url})" do
    test "goes to the screen showing, as :running" do
      {router, screen} = start_root()

      send(router, {:mob_link, @later})

      assert_receive {:screen_got, ^screen, %{url: @later, source: :running}}
    end

    test "goes to the registered process instead of the screen" do
      {router, _screen} = start_root()
      :ok = Mob.Link.register(self())

      send(router, {:mob_link, @later})

      assert_receive {:link, %{url: @later, source: :running}}
      refute_receive {:screen_got, _, _}, 50
    end

    test "falls back to the screen when the registered process is dead" do
      {router, screen} = start_root()
      dead = spawn(fn -> :ok end)
      ProcessHelpers.await_exit(dead)
      :ok = Mob.Link.register(dead)

      send(router, {:mob_link, @later})

      assert_receive {:screen_got, ^screen, %{url: @later}}
    end

    test "goes back to the screen after unregister" do
      {router, screen} = start_root()
      :ok = Mob.Link.register(self())
      :ok = Mob.Link.unregister()

      send(router, {:mob_link, @later})

      assert_receive {:screen_got, ^screen, %{url: @later}}
      refute_received {:link, _}
    end

    # The sender that stored has not poked the router yet when a live send
    # arrives; the stored link came first, so it is delivered first, and the
    # late poke finds nothing.
    test "a stored link is not overtaken by a live one" do
      {router, _screen} = start_root()
      StubNif.store(@launch)

      send(router, {:mob_link, @later})
      send(router, :mob_link_stored)

      assert links_received(2) == [{@launch, :launch}, {@later, :running}]
      refute_receive {:screen_got, _, _}, 50
    end
  end

  describe ":mob_link_stored" do
    # Native stored the link because the router was not registered when it
    # looked, then saw it registered. A second poke finds the store empty, so
    # the link arrives once.
    test "takes the stored link exactly once" do
      {router, screen} = start_root()
      StubNif.store(@launch)

      send(router, :mob_link_stored)
      send(router, :mob_link_stored)

      assert_receive {:screen_got, ^screen, %{url: @launch, source: :launch}}
      refute_receive {:screen_got, _, _}, 50
      assert StubNif.take_launch_link() == :none
    end
  end

  describe "a link stored before the router started" do
    # The link that cold-launches the app is stored before the BEAM is up; the
    # root screen must get it once it has mounted.
    test "is delivered once to the root screen after it mounts, as :launch" do
      StubNif.store(@launch)

      {router, screen} = start_root()

      assert_receive {:screen_got, ^screen, %{url: @launch, source: :launch}}

      send(router, :mob_link_stored)
      refute_receive {:screen_got, _, _}, 50
    end

    test "delivers every stored link, oldest first" do
      StubNif.store(@launch)
      StubNif.store(@later)

      start_root()

      assert links_received(2) == [{@launch, :launch}, {@later, :launch}]
      refute_receive {:screen_got, _, _}, 50
    end

    # A link sent live while the root screen mounts came in after the stored
    # one, so it must not overtake it.
    test "delivers stored links before one sent while the root mounts" do
      StubNif.store(@launch)

      start_root(%{live_during_mount: @later})

      assert links_received(2) == [{@launch, :launch}, {@later, :running}]
    end

    # Unlike a stored notification's target, the registration is Elixir-side
    # and this boot's, so a process registered before the root screen started
    # (an app's on_start) gets the link that launched the app.
    test "goes to a process registered before the root screen started" do
      StubNif.store(@launch)
      :ok = Mob.Link.register(self())

      start_root()

      assert_receive {:link, %{url: @launch, source: :launch}}
      refute_receive {:screen_got, _, _}, 50
    end
  end

  # The next `count` links the screen reported, as {url, source} in arrival
  # order (no selective receive, so a reordering shows).
  defp links_received(count) do
    for _ <- 1..count do
      assert_receive {:screen_got, _screen, %{url: url, source: source}}
      {url, source}
    end
  end
end
