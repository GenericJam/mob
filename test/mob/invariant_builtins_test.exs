defmodule Mob.Invariant.BuiltinsTest do
  use ExUnit.Case, async: false

  alias Mob.ComponentRegistry
  alias Mob.Invariant
  alias Mob.Invariant.Builtins

  setup do
    Invariant.reset()
    Mob.Test.ProcessHelpers.ensure_component_registry()

    # The registry is a global table and these tests deliberately leave orphans
    # in it. Clearing it here keeps one test's leak out of the next one's
    # assertions.
    if ComponentRegistry.table() != :undefined,
      do: :ets.delete_all_objects(ComponentRegistry.table())

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

    def handle_event("go_detail", _p, socket),
      do: {:noreply, Mob.Socket.push_screen(socket, Mob.Invariant.BuiltinsTest.DetailScreen)}

    def render(_a), do: %{type: :text, props: %{text: "nav"}, children: []}
  end

  defmodule DetailScreen do
    @moduledoc false
    use Mob.Screen
    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_a), do: %{type: :text, props: %{text: "detail"}, children: []}
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

      assert {:violations, [orphan]} = Builtins.orphaned_component(%{})
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

  describe "a leak that grows" do
    test "still confirms — one violation per orphan, not one carrying a list" do
      # The shape a broken reaping path actually produces: one more orphan per
      # navigation. Rolled into a single violation carrying a count, the details
      # changed on every sample, the fingerprint changed with them, and nothing
      # ever confirmed — the check saw the leak on 59 of 60 samples and reported
      # zero. Per-orphan candidacy is what fixes it: the older orphans are stable
      # while new ones accumulate.
      Application.put_env(:mob, :invariant_min_candidate_age_us, 0)
      on_exit(fn -> Application.delete_env(:mob, :invariant_min_candidate_age_us) end)

      Invariant.reset()
      Invariant.unregister(:dead_screen_in_nav)

      reported =
        for i <- 1..4 do
          owner = forever()
          component = forever()
          ComponentRegistry.register(owner, :"grow#{i}", SomeComponent, component)
          ref = Process.monitor(owner)
          send(owner, :stop)
          assert_receive {:DOWN, ^ref, :process, ^owner, _}

          length(Invariant.run(:on_screen_stop, %{}))
        end

      assert hd(reported) == 0, "the first sighting is a candidate, not a report"

      assert Enum.sum(reported) > 0,
             "a growing leak never confirmed: #{inspect(reported)}"
    end

    test "caps how many orphans one sample reports" do
      # Every reported violation is an ETS write on a teardown path, and a leak
      # of a thousand is not a thousand times more informative than a leak of
      # eight. The cap is also taken before building the maps — two inspect/1
      # calls per orphan ran inside terminate/2 on the router's stop path.
      for i <- 1..30 do
        owner = forever()
        component = forever()
        ComponentRegistry.register(owner, :"many#{i}", SomeComponent, component)
        ref = Process.monitor(owner)
        send(owner, :stop)
        assert_receive {:DOWN, ^ref, :process, ^owner, _}
      end

      assert {:violations, reported} = Builtins.orphaned_component(%{})
      assert length(reported) == 8
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

      assert {:violations, [entry]} = Builtins.dead_screen_in_nav(%{router: stub})
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

      assert [{NavScreen, first}] = Mob.Router.entries(router)
      assert first == Mob.Router.get_screen_pid(router)

      # History too, which is the half that matters: dead_screen_in_nav is only
      # meaningful over history and parked tabs — the current entry is alive by
      # construction. Returning just `state.current` left the suite green.
      # Pushed the way the app does, through the screen's own handler.
      Mob.Screen.dispatch(router, "go_detail", %{})

      entries = Mob.Router.entries(router)

      assert length(entries) == 2,
             "entries/1 must report history, not only the current screen: #{inspect(entries)}"

      assert Enum.sort(Enum.map(entries, fn {m, _} -> m end)) == [DetailScreen, NavScreen]
      assert Enum.all?(entries, fn {_m, p} -> is_pid(p) and Process.alive?(p) end)
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
