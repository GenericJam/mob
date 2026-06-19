defmodule Mob.ScreenCaseTest do
  use Mob.ScreenCase, async: true

  # A realistic fixture: core node types only, an explicit event, and a
  # tap-via-message path with a catch-all (the shape real screens use).
  defmodule CounterScreen do
    use Mob.Screen

    def mount(params, _session, socket) do
      {:ok, Mob.Socket.assign(socket, :count, Map.get(params, :start, 0))}
    end

    def render(assigns) do
      %{
        type: :column,
        props: %{},
        children: [
          %{type: :text, props: %{text: "Count: #{assigns.count}"}, children: []},
          %{type: :button, props: %{tag: "increment", label: "Add one"}, children: []}
        ]
      }
    end

    def handle_event("increment", _params, socket) do
      {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
    end

    def handle_info({:tap, :inc}, socket) do
      {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end

  # Renders a node type the native layer has no renderer for.
  defmodule BadScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      %{type: :column, props: %{}, children: [%{type: :hologram, props: %{}, children: []}]}
    end
  end

  # Pushes another screen, both from an explicit event and from a tap message.
  defmodule NavScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :column, props: %{}, children: []}

    def handle_event("go", _params, socket) do
      {:noreply, Mob.Socket.push_screen(socket, CounterScreen)}
    end

    def handle_info({:tap, :go}, socket) do
      {:noreply, Mob.Socket.push_screen(socket, CounterScreen)}
    end

    def handle_info(_message, socket), do: {:noreply, socket}
  end

  describe "mount_screen/3 + assigns/1" do
    test "mounts with initial assigns" do
      assert assigns(mount_screen(CounterScreen)).count == 0
    end

    test "passes params through to mount/3" do
      assert assigns(mount_screen(CounterScreen, %{start: 5})).count == 5
    end
  end

  describe "render_event/3" do
    test "dispatches handle_event and updates state + rendered text" do
      view = CounterScreen |> mount_screen() |> render_event("increment")
      assert assigns(view).count == 1
      assert text(view) =~ "Count: 1"
    end

    test "is chainable" do
      view =
        CounterScreen |> mount_screen() |> render_event("increment") |> render_event("increment")

      assert assigns(view).count == 2
    end
  end

  describe "render_info/2 (the tap path)" do
    test "delivers a message that handle_info acts on" do
      view = CounterScreen |> mount_screen() |> render_info({:tap, :inc})
      assert assigns(view).count == 1
    end

    test "an unhandled message hits the catch-all and noops" do
      view = CounterScreen |> mount_screen() |> render_info(:whatever)
      assert assigns(view).count == 0
    end
  end

  describe "tree queries" do
    setup do
      {:ok, view: mount_screen(CounterScreen)}
    end

    test "find/3 matches by type and a prop subset", %{view: view} do
      assert %{type: :button, props: %{label: "Add one"}} = find(view, :button, tag: "increment")
      assert find(view, :button, tag: "nope") == nil
    end

    test "find_all/3 returns every match", %{view: view} do
      assert length(find_all(view, :text)) == 1
    end

    test "flatten/1 walks the whole tree depth-first", %{view: view} do
      assert Enum.map(flatten(view), & &1.type) == [:column, :text, :button]
    end

    test "text/1 concatenates :text nodes", %{view: view} do
      assert text(view) == "Count: 0"
    end

    test "query helpers also accept a raw tree, not just a View", %{view: view} do
      raw = tree(view)
      assert find(raw, :button, tag: "increment")
      assert text(raw) == "Count: 0"
    end
  end

  describe "assert_renderable/2" do
    test "passes for a tree of core node types" do
      assert %{type: :column} = assert_renderable(mount_screen(CounterScreen))
    end

    test "flunks on a type with no native renderer" do
      view = mount_screen(BadScreen)

      assert_raise ExUnit.AssertionError, ~r/hologram/, fn ->
        assert_renderable(view)
      end
    end

    test ":extra allows a plugin/custom type through" do
      assert assert_renderable(mount_screen(BadScreen), extra: [:hologram])
    end

    test "renderable_types includes core tags and the native_view escape hatch" do
      types = renderable_types()
      assert MapSet.member?(types, :column)
      assert MapSet.member?(types, :text)
      assert MapSet.member?(types, :native_view)
    end
  end

  describe "navigated_to/1" do
    test "nil before any navigation" do
      assert navigated_to(mount_screen(CounterScreen)) == nil
    end

    test "records a push from an explicit event as the destination module" do
      view = NavScreen |> mount_screen() |> render_event("go")
      assert navigated_to(view) == CounterScreen
    end

    test "records a push from a tap (handle_info) as the destination module" do
      view = NavScreen |> mount_screen() |> render_info({:tap, :go})
      assert navigated_to(view) == CounterScreen
    end
  end

  # tree/1's :device clause must route to Mob.Test.tree/1 (the logical render
  # tree, shape %{type, props, children}) — NOT Mob.Test.view_tree/1, which is
  # the native accessibility tree (shape %{type, label, value, frame}) the query
  # helpers can't read. The @tag :on_device test below is excluded by default,
  # so this regression shipped undetected once; this pins the dispatch with no
  # device by exploiting the two functions' divergent behavior against a down
  # node: Mob.Test.tree/1 does `rpc(node, :inspect).tree` and so raises
  # BadMapError on the `{:badrpc, :nodedown}` it gets back, whereas
  # Mob.Test.view_tree/1 returns that tuple without raising.
  describe "tree/1 :device dispatch" do
    test "routes to Mob.Test.tree/1, not Mob.Test.view_tree/1" do
      view = device_view(:"nonexistent_node@127.0.0.1")
      assert_raise BadMapError, fn -> tree(view) end
    end
  end

  # The same assertion helpers, pointed at a live device over Mob.Test instead
  # of an in-process socket. Excluded by default (needs hardware + a connected
  # node); shown here as the worked example of the device backend.
  describe "device backend (@tag :on_device)" do
    @tag :on_device
    test "the same assertions run against a live device node" do
      node = :"mob_screen_case_demo@127.0.0.1"
      Mob.Test.navigate(node, CounterScreen)

      view = device_view(node)
      assert_renderable(view)
      assert navigated_to(view) == CounterScreen
    end
  end
end
