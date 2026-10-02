defmodule Mob.ScenesTest do
  @moduledoc """
  Several window scenes in one BEAM (MOB-245): one router per scene, routed by
  scene id, driven through `Mob.Test` with `scene:`.

  Native is a stub that plays iOS: it reports scenes, answers per-scene reads
  and records every committed frame, so these tests see which window a frame
  went to. See `decisions/2026-10-02-one-router-per-window-scene.md`.
  """
  use ExUnit.Case, async: false

  alias Mob.Test.ProcessHelpers

  defmodule HomeScreen do
    use Mob.Screen

    def mount(params, _session, socket),
      do: {:ok, Mob.Socket.assign(socket, test: params[:test], n: 0)}

    def render(assigns),
      do: %{type: :text, props: %{text: "home #{assigns.n}", on_tap: {self(), :n}}, children: []}

    def handle_info({:tap, :hello}, socket) do
      send(socket.assigns.test, {:tapped, self()})
      {:noreply, socket}
    end

    def handle_info({:tap, :detail}, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.ScenesTest.DetailScreen)}

    def handle_info({:alert, action}, socket) do
      send(socket.assigns.test, {:alert, self(), action})
      {:noreply, socket}
    end

    def handle_info(_other, socket), do: {:noreply, socket}
  end

  defmodule DetailScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "detail"}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: Mob.ScenesTest.HomeScreen)
  end

  # iOS as the BEAM sees it. Every committed frame goes to the test process as
  # {:frame, built_for, root_scene_key, root}: `built_for` is what clear_taps
  # named (:default for clear_taps/0), `root` carries the transition set for
  # it. `scenes/0` reports what the test configured.
  defmodule Nif do
    @key {__MODULE__, :state}

    def configure(test, scenes) do
      :persistent_term.put(@key, %{test: test, scenes: scenes, building: nil, transition: nil})
    end

    defp state, do: :persistent_term.get(@key)
    defp update(fun), do: :persistent_term.put(@key, fun.(state()))

    def platform, do: :ios
    def scenes, do: state().scenes
    def take_launch_notification, do: :none
    def webview_can_go_back, do: false
    def exit_app, do: :ok
    def safe_area, do: {10.0, 0.0, 0.0, 0.0}
    def safe_area("B"), do: {20.0, 0.0, 0.0, 0.0}
    def safe_area(_scene), do: {30.0, 0.0, 0.0, 0.0}
    def size_class, do: {:regular, :regular}
    def size_class(_scene), do: {:compact, :regular}
    def clear_taps, do: update(&%{&1 | building: :default})
    def clear_taps(scene), do: update(&%{&1 | building: scene})
    def set_transition(transition), do: update(&%{&1 | transition: transition})
    def register_tap(_handler), do: 0

    def set_root(json) do
      root = :json.decode(json)
      state = state()
      root = Map.put(root, "transition", state.transition)
      send(state.test, {:frame, state.building, root["scene"], root})
      :ok
    end
  end

  setup do
    for name <- [Mob.Scenes, Mob.Sender, Mob.Listener, Mob.Nav.Registry] do
      ProcessHelpers.stop_if_running(name)
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> ProcessHelpers.stop_pid(registry) end)
    :ok
  end

  # The app's root, as on_start starts it, with native already reporting
  # `scenes` (oldest first; the first one is native's default).
  defp boot(scenes) do
    Nif.configure(self(), Enum.with_index(scenes, fn id, i -> {id, i == 0} end))
    {:ok, primary} = Mob.Router.start_root(HomeScreen, %{test: self()}, nif: Nif)
    on_exit(fn -> ProcessHelpers.stop_root(primary) end)
    settle()
    primary
  end

  # Mob.Scenes has handled everything sent to it, every router it knows has
  # handled everything sent to it, and every frame is committed.
  defp settle do
    :sys.get_state(Mob.Scenes)

    for {_scene, router} <- Mob.Scenes.list() do
      :sys.get_state(router)
      :sys.get_state(Mob.Router.get_screen_pid(router))
    end

    Mob.Sender.sync()
  end

  defp connect(scene, default? \\ false) do
    send(Mob.Scenes, {:mob_scene, :connected, scene, default?})
    settle()
  end

  defp disconnect(scene) do
    send(Mob.Scenes, {:mob_scene, :disconnected, scene})
    settle()
  end

  defp router(scene), do: Mob.Scenes.router(scene)
  defp module(scene), do: Mob.Router.get_current_module(router(scene))
  defp socket(scene), do: Mob.Router.get_socket(router(scene))
  defp screen_pid(scene), do: Mob.Router.get_screen_pid(router(scene))

  defp flush_frames do
    receive do
      {:frame, _, _, _} -> flush_frames()
    after
      0 -> :ok
    end
  end

  describe "one router per scene" do
    test "the app's root router shows native's default scene, unbound" do
      primary = boot(["A"])

      assert Mob.Scenes.list() == [{"A", primary}]
      assert Process.whereis(:mob_screen) == primary
      # Built and committed exactly as before scenes existed: clear_taps/0 and
      # no "scene" key on the root.
      assert_received {:frame, :default, nil, _root}
    end

    test "a scene that connects later gets its own router on the root screen, bound to its id" do
      primary = boot(["A"])
      flush_frames()

      connect("B")

      assert [{"A", ^primary}, {"B", second}] = Mob.Scenes.list()
      refute second == primary
      assert module("B") == HomeScreen
      # Its frames are built for and committed into scene B.
      assert_received {:frame, "B", "B", %{"props" => %{"text" => "home 0"}}}
      # :mob_screen still names the app's root router.
      assert Process.whereis(:mob_screen) == primary
    end

    test "a bound screen reads its own window's insets and size class" do
      boot(["A"])
      connect("B")

      assert socket("A").assigns.safe_area.top == 10.0
      assert socket("A").assigns.size_class == {:regular, :regular}
      assert socket("B").assigns.safe_area.top == 20.0
      assert socket("B").assigns.size_class == {:compact, :regular}
      assert Mob.Scene.of(socket("B")) == "B"
      assert Mob.Scene.of(socket("A")) == nil
    end

    test "scenes native reported before the root started each get a router once it does" do
      primary = boot(["A", "B", "C"])

      assert [{"A", ^primary}, {"B", b}, {"C", c}] = Mob.Scenes.list()
      assert b != c
      assert module("C") == HomeScreen
    end

    test "navigating one window leaves the other where it was" do
      boot(["A"])
      connect("B")

      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "B")

      assert module("B") == DetailScreen
      assert module("A") == HomeScreen
    end

    test "both windows' frames are committed, each into its own scene with its transition" do
      boot(["A"])
      connect("B")
      flush_frames()

      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "B")
      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "A")
      settle()

      assert_received {:frame, "B", "B",
                       %{"props" => %{"text" => "detail"}, "transition" => :push}}

      assert_received {:frame, :default, nil,
                       %{"props" => %{"text" => "detail"}, "transition" => :push}}
    end
  end

  describe "window events" do
    test "the back gesture of one scene pops only that scene's stack" do
      boot(["A"])
      connect("B")
      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "A")
      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "B")

      send(Mob.Scenes, {:mob_scene_event, "B", {:mob, :back}})
      settle()

      assert module("B") == HomeScreen
      assert module("A") == DetailScreen
    end

    test "a size class change reaches only the window it happened in" do
      boot(["A"])
      connect("B")

      send(Mob.Scenes, {:mob_scene_event, "B", {:mob_size_class, :regular, :compact}})
      settle()

      assert socket("B").assigns.size_class == {:regular, :compact}
      assert socket("A").assigns.size_class == {:regular, :regular}
    end

    test "an alert result for one window reaches that window's screen" do
      boot(["A"])
      connect("B")

      send(Mob.Scenes, {:mob_scene_event, "B", {:alert, :confirmed}})

      in_b = screen_pid("B")
      assert_receive {:alert, ^in_b, :confirmed}
      refute_receive {:alert, _, _}, 50
    end
  end

  describe "disconnect and reconnect" do
    test "a closed window's router stops; the others keep running" do
      primary = boot(["A"])
      connect("B")
      second = router("B")
      ref = Process.monitor(second)

      disconnect("B")

      assert_receive {:DOWN, ^ref, :process, ^second, _}
      assert Mob.Scenes.list() == [{"A", primary}]
    end

    test "when the root's window closes, :mob_screen moves to a remaining window's router" do
      primary = boot(["A"])
      connect("B")
      second = router("B")
      ref = Process.monitor(primary)

      disconnect("A")

      assert_receive {:DOWN, ^ref, :process, ^primary, _}
      assert Process.whereis(:mob_screen) == second
      assert Mob.Test.screens(node()) == [{"B", HomeScreen, Mob.Router.get_screen_pid(second)}]
      assert Mob.Test.screen(node()) == HomeScreen
    end

    test "the last window's router is kept, with its screens, and comes back with the window" do
      primary = boot(["A"])
      :ok = Mob.Test.navigate(node(), DetailScreen)

      disconnect("A")
      assert Process.alive?(primary)

      connect("A", true)
      assert Mob.Scenes.list() == [{"A", primary}]
      assert Mob.Test.screen(node()) == DetailScreen
    end

    test "a new session after the last window went away adopts the kept router" do
      boot(["A"])
      connect("B")
      second = router("B")
      disconnect("A")
      disconnect("B")
      flush_frames()

      connect("C", true)

      assert Mob.Scenes.list() == [{"C", second}]
      assert_received {:frame, "C", "C", _root}
      assert Mob.Scene.of(socket("C")) == "C"
    end
  end

  describe "Mob.Test" do
    test "screens/1 lists what every window shows" do
      primary = boot(["A"])
      connect("B")
      :ok = Mob.Test.navigate(node(), DetailScreen, %{}, scene: "B")

      assert Mob.Test.screens(node()) == [
               {"A", HomeScreen, Mob.Router.get_screen_pid(primary)},
               {"B", DetailScreen, screen_pid("B")}
             ]
    end

    test "with one window, screen/1, tap/2 and screens/1 work as before" do
      primary = boot(["A"])
      screen = Mob.Router.get_screen_pid(primary)

      assert Mob.Test.screens(node()) == [{"A", HomeScreen, screen}]
      assert Mob.Test.screen(node()) == HomeScreen

      :ok = Mob.Test.tap(node(), :hello)
      assert_receive {:tapped, ^screen}
    end

    test "with several windows, screen/1 raises MultipleScenesError naming them" do
      boot(["A"])
      connect("B")

      error = assert_raise Mob.Test.MultipleScenesError, fn -> Mob.Test.screen(node()) end
      message = Exception.message(error)

      assert message =~ "Mob.Test.screen/1"
      assert message =~ ~s("A" showing Mob.ScenesTest.HomeScreen)
      assert message =~ ~s("B" showing Mob.ScenesTest.HomeScreen)
      assert message =~ "scene:"
    end

    test "with several windows, helpers that address the current screen need scene:" do
      boot(["A"])
      connect("B")

      assert_raise Mob.Test.MultipleScenesError, fn -> Mob.Test.tap(node(), :hello) end
      assert_raise Mob.Test.MultipleScenesError, fn -> Mob.Test.assigns(node()) end
      assert_raise Mob.Test.MultipleScenesError, fn -> Mob.Test.pop(node()) end
      refute_received {:tapped, _}
    end

    test "tap/3 with scene: reaches that window's screen and no other" do
      boot(["A"])
      connect("B")
      in_b = screen_pid("B")

      :ok = Mob.Test.tap(node(), :hello, scene: "B")

      assert_receive {:tapped, ^in_b}
      refute_receive {:tapped, _}, 50
    end

    test "scene: drives navigation and inspection of that window" do
      boot(["A"])
      connect("B")

      :ok = Mob.Test.tap(node(), :detail, scene: "B")
      Mob.Test.settle(node())

      assert Mob.Test.screen(node(), scene: "B") == DetailScreen
      assert Mob.Test.screen(node(), scene: "A") == HomeScreen
      assert Mob.Test.assigns(node(), scene: "A").n == 0

      :ok = Mob.Test.back(node(), scene: "B")
      Mob.Test.settle(node())
      assert Mob.Test.screen(node(), scene: "B") == HomeScreen
    end

    test "an unknown scene: is an ArgumentError listing the live ones" do
      boot(["A"])

      error = assert_raise ArgumentError, fn -> Mob.Test.screen(node(), scene: "Z") end
      assert Exception.message(error) =~ ~s(no window scene "Z")
      assert Exception.message(error) =~ ~s(["A"])
    end
  end

  describe "Mob.Sender" do
    test "commits the active screen of every scene, each with its own transition" do
      Nif.configure(self(), [])
      {:ok, sender} = Mob.Sender.start_link([])
      on_exit(fn -> ProcessHelpers.stop_pid(sender) end)

      tree = fn text -> %{type: :text, props: %{text: text}, children: []} end
      token_a = Mob.Sender.activate_frame(:screen_a, :none, nil)
      token_b = Mob.Sender.activate_frame(:screen_b, :push, "B")

      Mob.Sender.render(:screen_a, tree.("a"), :ios, Nif, :none, token_a)
      Mob.Sender.render(:screen_b, tree.("b"), :ios, Nif, :none, token_b)
      # A screen active nowhere is dropped, whatever scene it thinks it is in.
      Mob.Sender.render(:parked, tree.("parked"), :ios, Nif, :none)
      Mob.Sender.sync()

      assert_received {:frame, :default, nil,
                       %{"props" => %{"text" => "a"}, "transition" => :none}}

      assert_received {:frame, "B", "B", %{"props" => %{"text" => "b"}, "transition" => :push}}
      refute_received {:frame, _, _, %{"props" => %{"text" => "parked"}}}
    end

    test "a deactivated scene gets no more frames" do
      Nif.configure(self(), [])
      {:ok, sender} = Mob.Sender.start_link([])
      on_exit(fn -> ProcessHelpers.stop_pid(sender) end)

      Mob.Sender.activate(:screen_b, :none, "B")
      Mob.Sender.deactivate_scene("B")
      Mob.Sender.render(:screen_b, %{type: :text, props: %{}, children: []}, :ios, Nif, :none)
      Mob.Sender.sync()

      refute_received {:frame, _, _, _}
    end
  end
end
