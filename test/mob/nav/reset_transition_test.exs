defmodule Mob.Nav.ResetTransitionTest do
  @moduledoc """
  `reset_to/4`'s `:transition` option, end to end.

  The socket-level tests assert the nav action's shape; these assert the thing
  the option exists for — that the chosen animation actually reaches
  `set_transition/1` on the native boundary. A reset that recorded `:push` in
  its action and still painted `:reset` would pass a shape test and be useless.

  Runs in `:render` with an injected NIF, since `do_paint` short-circuits under
  `:no_render` and the transition would never be observable.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule HomeScreen do
    use Mob.Screen

    @other Mob.Nav.ResetTransitionTest.OtherScreen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}

    def handle_event("reset_default", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other)}

    def handle_event("reset_push", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other, %{}, transition: :push)}

    def handle_event("reset_pop", _, socket),
      do: {:noreply, Mob.Socket.reset_to(socket, @other, %{}, transition: :pop)}

    def handle_event("push_other", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, @other)}
  end

  defmodule OtherScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "other"}, children: []}

    def handle_event("go_back", _, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

    def handle_event("push_third", _, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.Nav.ResetTransitionTest.ThirdScreen)}
  end

  defmodule ThirdScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "third"}, children: []}

    def handle_event("to_root", _, socket), do: {:noreply, Mob.Socket.pop_to_root(socket)}

    def handle_event("to_other", _, socket),
      do: {:noreply, Mob.Socket.pop_to(socket, Mob.Nav.ResetTransitionTest.OtherScreen)}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    @home Mob.Nav.ResetTransitionTest.HomeScreen
    def navigation(_), do: stack(:home, root: @home)
  end

  defmodule RecordingNif do
    def start, do: Agent.start(fn -> [transitions: [], roots: []] end, name: __MODULE__)

    def transitions,
      do: __MODULE__ |> Agent.get(&Keyword.get(&1, :transitions, [])) |> Enum.reverse()

    def last_root, do: List.last(roots())

    def roots,
      do: __MODULE__ |> Agent.get(&Keyword.get(&1, :roots, [])) |> Enum.reverse()

    def reset, do: Agent.update(__MODULE__, fn _ -> [transitions: [], roots: []] end)

    def platform, do: :android
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def take_launch_notification, do: :none
    def clear_taps, do: :ok
    def register_tap(_), do: 0

    def set_root(json) do
      Agent.update(__MODULE__, fn state ->
        Keyword.update(state, :roots, [json], &[json | &1])
      end)

      :ok
    end

    def set_transition(t) do
      Agent.update(__MODULE__, fn state ->
        Keyword.update(state, :transitions, [t], &[t | &1])
      end)

      :ok
    end
  end

  defp stop_safely(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # The transition for the frame the reset painted, ignoring the initial mount.
  defp last_transition do
    Mob.Sender.sync(:infinity)
    List.last(RecordingNif.transitions())
  end

  # Whether the frame told native the navigation stack was replaced. Carried on
  # the JSON root rather than in the transition atom, so the transition
  # vocabulary native matches on stays closed — see `replaces?/0`'s callers.
  defp replaced_stack? do
    Mob.Sender.sync(:infinity)
    Enum.any?(RecordingNif.roots(), &Map.get(:json.decode(&1), "replaces_stack", false))
  end

  setup do
    for name <- [Mob.Nav.Registry, Mob.Sender, Mob.Listener, Mob.ComponentRegistry],
        pid = Process.whereis(name) do
      stop_safely(pid)
    end

    # The render path reconciles components, which needs the registry's table.
    {:ok, components} = Mob.ComponentRegistry.start_link()

    # Stop everything this file caused to start, not just what it started
    # directly. Mob.Router brings up the Sender and Listener under their global
    # names; leaving them behind is what produces cross-file ordering flakes.
    on_exit(fn ->
      stop_safely(components)

      for name <- [Mob.Sender, Mob.Listener], pid = Process.whereis(name) do
        stop_safely(pid)
      end

      case Process.whereis(RecordingNif) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end)

    case Process.whereis(RecordingNif) do
      nil -> RecordingNif.start()
      pid -> Agent.stop(pid) && RecordingNif.start()
    end

    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    on_exit(fn -> stop_safely(registry) end)

    {:ok, router} = Mob.Router.start_root(HomeScreen, %{}, nif: RecordingNif)
    on_exit(fn -> stop_safely(router) end)

    RecordingNif.reset()
    %{router: router}
  end

  describe "the chosen transition reaches the native boundary" do
    test "a plain reset still cross-fades, and marks the stack replaced", %{router: router} do
      Mob.Router.dispatch(router, "reset_default", %{})
      # The transition atom stays in the closed `:push | :pop | :reset | :none`
      # vocabulary; the "stack was replaced" fact rides on the JSON root
      # instead. Android matches the transition as a raw string with an exact
      # `when`, so a decorated atom would fall to `else` and silently lose its
      # animation. The flag tells native the outgoing screen is unreachable, so
      # the view tree MOB-129 would otherwise retain for a return can go.
      assert last_transition() == :reset
      assert replaced_stack?()
    end

    test "transition: :push paints a push and still replaces", %{router: router} do
      Mob.Router.dispatch(router, "reset_push", %{})
      assert last_transition() == :push
      assert replaced_stack?()
    end

    test "transition: :pop paints a pop", %{router: router} do
      Mob.Router.dispatch(router, "reset_pop", %{})
      assert last_transition() == :pop
      assert replaced_stack?()
    end

    test "the stack is still replaced, whatever the animation", %{router: router} do
      Mob.Router.dispatch(router, "reset_push", %{})

      assert Mob.Router.get_current_module(router) == OtherScreen
      assert Mob.Router.get_nav_history(router) == []
    end
  end

  describe "an action shape the router does not know" do
    test "is ignored rather than killing navigation and every screen", %{router: router} do
      # Reachable during a hot code push: module loading is not atomic, so a
      # screen already on new code can hand an action to a router still on old
      # code. Unmatched, that is a FunctionClauseError in the owner.
      screen = Mob.Router.get_screen_pid(router)

      log =
        capture_log(fn ->
          :ok = GenServer.call(router, {:navigate, {:reset, OtherScreen, %{}, :push, :extra}})
        end)

      assert log =~ "unrecognised navigation action"
      assert Process.alive?(router)
      assert Process.alive?(screen)
      assert Mob.Router.get_current_module(router) == HomeScreen
    end
  end

  describe "the legacy three-element action" do
    test "still resets, and still cross-fades", %{router: router} do
      # Arrives from Mob.Test.reset_to/3 and from any socket built before a hot
      # code push. Dropping it would break navigation across an upgrade.
      :ok = GenServer.call(router, {:navigate, {:reset, OtherScreen, %{}}})

      assert last_transition() == :reset
      assert replaced_stack?()
      assert Mob.Router.get_current_module(router) == OtherScreen
    end
  end

  describe "a pop also releases the screen it left behind" do
    # MOB-147 S3. `pop` stops the outgoing screen's process, so the view tree
    # the two-slot presenter retains for it can never be shown again: the next
    # navigation always writes into the *other* slot. Tagging it releases that
    # tree when the animation ends instead of at the next navigation. Measured
    # on an iPhone SE over eight pops of a dense screen, this did not cost the
    # main-thread teardown it might have: median native apply fell 42.8ms ->
    # 39.4ms. Leaving pop untagged was the inconsistency this closes.
    test "pop marks the stack replaced", %{router: router} do
      Mob.Router.dispatch(router, "push_other", %{})
      Mob.Sender.sync(:infinity)
      RecordingNif.reset()

      Mob.Router.dispatch(router, "go_back", %{})

      assert last_transition() == :pop
      assert replaced_stack?()
    end

    test "a push does not - the screen it leaves is still on the stack", %{router: router} do
      RecordingNif.reset()
      Mob.Router.dispatch(router, "push_other", %{})
      Mob.Sender.sync(:infinity)

      assert :push in RecordingNif.transitions()
      refute replaced_stack?()
    end
  end

  describe "a reset that asks for no animation" do
    # MOB-147 N2. `Mob.Socket.reset_to/4` rejects `:none`, but the router also
    # takes raw nav actions - from `Mob.Test.reset_to/4`, which does not
    # validate, and from sockets built before a hot code push. `:none` must
    # stay untagged: with no animation there is no completion callback to
    # release on, and the incoming screen reuses the outgoing one's view
    # identities, so releasing the slot would pull the tree out from under it.
    test "the socket API refuses to build one" do
      assert_raise ArgumentError, fn ->
        Mob.Socket.reset_to(%Mob.Socket{}, OtherScreen, %{}, transition: :none)
      end
    end

    test "but Mob.Test.reset_to/4 does not validate, so the router still sees it",
         %{router: router} do
      # This is what makes `replacing(:none)` live rather than dead code, and it
      # is asserted through the real public API rather than by inspecting an
      # action shape. `Mob.Test` drives the router by its registered
      # `:mob_screen` name, so pointing it at this node reaches the router this
      # test started. If this ever raises, the guard can go — but not before.
      RecordingNif.reset()

      assert :ok = Mob.Test.reset_to(node(), OtherScreen, %{}, transition: :none)

      assert Mob.Router.get_current_module(router) == OtherScreen
      :sys.get_state(:sys.get_state(router).current.pid)
      Mob.Sender.sync(:infinity)

      # Driven synchronously this paints twice; what matters is that no frame
      # asked for an animation, and that none was tagged.
      assert RecordingNif.transitions() != []
      assert Enum.all?(RecordingNif.transitions(), &(&1 == :none))
      refute replaced_stack?()
    end

    test "is painted without an animation and without the flag", %{router: router} do
      current = :sys.get_state(router).current.pid
      RecordingNif.reset()

      send(router, {:nav_action, {:reset, OtherScreen, %{}, :none}, current})

      # A raw nav action arrives as a message, and its paint is async: the
      # router tells the incoming screen to render and that screen casts to the
      # sender. `Mob.Sender.sync/1` only orders the *caller's* own casts, so
      # step through both processes first or the flush races the paint.
      assert Mob.Router.get_current_module(router) == OtherScreen
      :sys.get_state(:sys.get_state(router).current.pid)
      Mob.Sender.sync(:infinity)

      assert RecordingNif.roots() != []
      assert RecordingNif.transitions() == [:none]
      refute replaced_stack?()
    end
  end

  describe "every navigation that stops the screen it leaves is tagged" do
    # MOB-147 S3, review finding (b): the pop path had one test, through
    # `pop_screen`, while `pop_to`, `pop_to_root` and the failed-restart
    # recovery went untested. Reverting the tag at three of the four sites left
    # the whole suite green.
    setup %{router: router} do
      Mob.Router.dispatch(router, "push_other", %{})
      Mob.Router.dispatch(router, "push_third", %{})
      Mob.Sender.sync(:infinity)
      assert Mob.Router.get_current_module(router) == ThirdScreen
      RecordingNif.reset()
      :ok
    end

    test "pop_to_root", %{router: router} do
      Mob.Router.dispatch(router, "to_root", %{})

      assert Mob.Router.get_current_module(router) == HomeScreen
      assert last_transition() == :pop
      assert replaced_stack?()
    end

    test "pop_to a screen mid-stack", %{router: router} do
      Mob.Router.dispatch(router, "to_other", %{})

      assert Mob.Router.get_current_module(router) == OtherScreen
      assert last_transition() == :pop
      assert replaced_stack?()
    end
  end
end
