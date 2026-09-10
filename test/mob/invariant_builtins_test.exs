defmodule Mob.Invariant.BuiltinsTest do
  use ExUnit.Case, async: false

  alias Mob.ComponentRegistry
  alias Mob.Invariant
  alias Mob.Invariant.Builtins

  setup do
    Invariant.reset()
    Mob.Test.ProcessHelpers.ensure_component_registry()
    on_exit(&Invariant.reset/0)
    :ok
  end

  defmodule FakeRouter do
    @moduledoc false
    use GenServer

    def start_link(entries), do: GenServer.start_link(__MODULE__, entries)

    @impl GenServer
    def init(entries), do: {:ok, entries}

    @impl GenServer
    def handle_call(:__entries__, _from, entries), do: {:reply, entries, entries}
  end

  defmodule NavScreen do
    @moduledoc false
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_a), do: %{type: :text, props: %{text: "nav"}, children: []}
  end

  defmodule Nif do
    @moduledoc false
    def safe_area, do: {0.0, 0.0, 0.0, 0.0}
    def platform, do: :ios
    def take_launch_notification, do: :none
    def unquote(:"$handle_undefined_function")(_f, _a), do: :ok
  end

  defp forever do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "orphaned_component/1" do
    test "a live component under a dead owner is a violation" do
      # The class three of the four agents in MOB-149 named independently: a
      # leaked component process still holding a native handle after the screen
      # that owned it is gone.
      dead_owner = forever()
      component = forever()
      ComponentRegistry.register(dead_owner, :leaky, SomeComponent, component)

      ref = Process.monitor(dead_owner)
      send(dead_owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^dead_owner, _}

      assert {:violation, %{count: 1, orphans: [orphan]}} = Builtins.orphaned_component(%{})
      assert orphan.id == :leaky
      assert orphan.module == SomeComponent

      send(component, :stop)
    end

    test "a live component under a live owner is fine" do
      owner = forever()
      component = forever()
      ComponentRegistry.register(owner, :ok_one, SomeComponent, component)

      assert Builtins.orphaned_component(%{}) == :ok

      send(owner, :stop)
      send(component, :stop)
    end

    test "a dead component under a dead owner is not a leak" do
      # Both gone is the normal end of a screen's life. Reporting it would make
      # every teardown a defect.
      owner = forever()
      component = forever()
      ComponentRegistry.register(owner, :both_gone, SomeComponent, component)

      for {pid, ref} <- [{owner, Process.monitor(owner)}, {component, Process.monitor(component)}] do
        send(pid, :stop)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end

      assert Builtins.orphaned_component(%{}) == :ok
    end
  end

  describe "dead_screen_in_nav/1" do
    test "finds a dead screen the router is still holding" do
      # A stub answering the same call `Mob.Router.entries/1` makes. Driving a
      # real router cannot produce this state on demand — it restarts a killed
      # screen — and a test that tolerates either outcome cannot fail, which is
      # exactly how the first version of this passed with the check gutted.
      dead = forever()
      ref = Process.monitor(dead)
      send(dead, :stop)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      {:ok, stub} = FakeRouter.start_link([{NavScreen, dead}])
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(stub) end)

      assert {:violation, %{count: 1, dead_entries: [entry]}} =
               Builtins.dead_screen_in_nav(%{router: stub})

      assert entry.module == NavScreen
    end

    test "a router holding only live screens is fine" do
      {:ok, stub} = FakeRouter.start_link([{NavScreen, self()}])
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_pid(stub) end)

      assert Builtins.dead_screen_in_nav(%{router: stub}) == :ok
    end

    test "returns :ok without a router in the context" do
      # A check that raises when its context is missing would be reported as a
      # failed check on every sample at the wrong sampling point.
      assert Builtins.dead_screen_in_nav(%{}) == :ok
    end

    test "returns :ok when the router itself is gone" do
      router = forever()
      ref = Process.monitor(router)
      send(router, :stop)
      assert_receive {:DOWN, ^ref, :process, ^router, _}

      assert Builtins.dead_screen_in_nav(%{router: router}) == :ok
    end
  end

  describe "Mob.Router.entries/1" do
    test "returns every entry the router holds, with live pids" do
      # A new public API this change adds, and the only reason
      # dead_screen_in_nav can see pids at all. It had no coverage: making it
      # return [] left the whole suite green.
      {:ok, router} = Mob.Router.start_root(NavScreen, %{}, nif: Nif)
      on_exit(fn -> Mob.Test.ProcessHelpers.stop_root(router) end)

      entries = Mob.Router.entries(router)

      assert [{NavScreen, pid}] = entries
      assert is_pid(pid) and Process.alive?(pid)
      assert pid == Mob.Router.get_screen_pid(router)
    end
  end

  describe "the sampling point is actually wired" do
    test "stopping a real screen samples :on_screen_stop" do
      # The only production call site of this feature. Deleting it left 1642
      # tests green.
      Invariant.reset()
      Invariant.unregister(:orphaned_component)
      Invariant.unregister(:dead_screen_in_nav)

      me = self()

      Invariant.register(:probe,
        at: :on_screen_stop,
        severity: :warning,
        check: fn ctx ->
          send(me, {:sampled, ctx[:screen_module]})
          :ok
        end
      )

      {:ok, router} = Mob.Router.start_root(NavScreen, %{}, nif: Nif)
      Mob.Test.ProcessHelpers.stop_root(router)

      assert_receive {:sampled, NavScreen}, 1_000
    end
  end

  describe "install/0 and the honest gap" do
    test "the built-ins are installed without anyone calling install/0" do
      # The production path: nothing in lib/ calls install/0 directly, the owner
      # does it on first use. Both other tests here call it explicitly, which
      # masked whether that path worked at all.
      Invariant.reset()

      names =
        [:on_screen_stop, :periodic]
        |> Enum.flat_map(&Invariant.registered/1)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == [:dead_screen_in_nav, :orphaned_component]
    end

    test "registers exactly the checks that are implemented" do
      Builtins.install()

      registered =
        (Invariant.registered(:on_screen_stop) ++ Invariant.registered(:periodic))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert registered == [:dead_screen_in_nav, :orphaned_component]
    end

    test "no unimplemented check is silently registered" do
      # MOB-156 names ten. Registering a name from `unimplemented/0` would mean
      # the registry claims a check it does not run — the kind of overclaim this
      # epic keeps having to retract.
      Builtins.install()

      registered =
        [:on_screen_stop, :periodic, :after_committed_frame]
        |> Enum.flat_map(&Invariant.registered/1)
        |> MapSet.new(& &1.name)

      for {name, _why} <- Builtins.unimplemented() do
        refute MapSet.member?(registered, name),
               "#{name} is listed as unimplemented but is registered"
      end
    end

    test "install/0 is idempotent" do
      Builtins.install()
      Builtins.install()

      assert length(Invariant.registered(:on_screen_stop)) == 1
      assert length(Invariant.registered(:periodic)) == 1
    end

    test "every unimplemented entry names a check and says what it needs" do
      # The list is the honest half of "ten checks": it has to stay specific
      # enough to act on, not decay into a TODO.
      entries = Builtins.unimplemented()

      assert length(entries) == 8

      for {name, why} <- entries do
        assert name == :"#{name}", "#{inspect(name)} should be an atom naming the check"
        assert String.length(why) > 20, "#{name} has no explanation of what is missing"
      end
    end
  end
end
