defmodule Mob.ComponentTest do
  use ExUnit.Case, async: true

  # Tests cover pure Elixir behaviour — mount, render, handle_event, update.
  # The NIF-calling path (register_component) requires a device and is tested on-device.

  defmodule CounterComponent do
    use Mob.Component

    def mount(props, socket) do
      {:ok, Mob.Socket.assign(socket, :count, props[:initial] || 0)}
    end

    def render(assigns) do
      %{count: assigns.count}
    end

    def handle_event("increment", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
    end
  end

  defmodule StatelessComponent do
    use Mob.Component

    def render(assigns) do
      %{label: assigns[:label] || ""}
    end
  end

  # ── Mob.Component behaviour defaults ──────────────────────────────────────

  describe "use Mob.Component" do
    test "mount/2 default returns {:ok, socket} unchanged" do
      socket = Mob.Socket.new(StatelessComponent, platform: :no_render)
      assert {:ok, ^socket} = StatelessComponent.mount(%{}, socket)
    end

    test "update/2 default delegates to mount/2" do
      socket = Mob.Socket.new(CounterComponent, platform: :no_render)
      {:ok, mounted} = CounterComponent.mount(%{initial: 5}, socket)
      {:ok, updated} = CounterComponent.update(%{initial: 10}, mounted)
      assert updated.assigns.count == 10
    end

    test "terminate/2 default returns :ok" do
      socket = Mob.Socket.new(StatelessComponent, platform: :no_render)
      assert :ok = StatelessComponent.terminate(:normal, socket)
    end

    test "handle_event/3 default raises for unhandled events" do
      socket = Mob.Socket.new(StatelessComponent, platform: :no_render)

      assert_raise RuntimeError, ~r/unhandled component event/, fn ->
        StatelessComponent.handle_event("unknown", %{}, socket)
      end
    end
  end

  # ── CounterComponent callbacks ─────────────────────────────────────────────

  describe "CounterComponent" do
    test "mount/2 assigns initial count from props" do
      socket = Mob.Socket.new(CounterComponent, platform: :no_render)
      {:ok, mounted} = CounterComponent.mount(%{initial: 7}, socket)
      assert mounted.assigns.count == 7
    end

    test "mount/2 defaults count to 0 when :initial absent" do
      socket = Mob.Socket.new(CounterComponent, platform: :no_render)
      {:ok, mounted} = CounterComponent.mount(%{}, socket)
      assert mounted.assigns.count == 0
    end

    test "render/1 returns props map with count" do
      socket = Mob.Socket.new(CounterComponent, platform: :no_render)
      {:ok, mounted} = CounterComponent.mount(%{initial: 3}, socket)
      assert CounterComponent.render(mounted.assigns) == %{count: 3}
    end

    test "handle_event increment increments count" do
      socket = Mob.Socket.new(CounterComponent, platform: :no_render)
      {:ok, mounted} = CounterComponent.mount(%{initial: 0}, socket)
      {:noreply, updated} = CounterComponent.handle_event("increment", %{}, mounted)
      assert updated.assigns.count == 1
    end
  end

  # ── Mob.UI.native_view ────────────────────────────────────────────────────

  describe "Mob.UI.native_view/2" do
    test "returns a :native_view node" do
      node = Mob.UI.native_view(CounterComponent, id: :counter)
      assert node.type == :native_view
    end

    test "includes the module in props" do
      node = Mob.UI.native_view(CounterComponent, id: :counter)
      assert node.props.module == CounterComponent
    end

    test "includes the id in props" do
      node = Mob.UI.native_view(CounterComponent, id: :counter)
      assert node.props.id == :counter
    end

    test "includes extra props" do
      node = Mob.UI.native_view(CounterComponent, id: :counter, initial: 5)
      assert node.props.initial == 5
    end

    test "children is always empty" do
      assert Mob.UI.native_view(CounterComponent, id: :counter).children == []
    end

    test "accepts a map" do
      node = Mob.UI.native_view(CounterComponent, %{id: :counter})
      assert node.props.id == :counter
    end
  end

  describe "Mob.Component.expand/3" do
    setup do
      {:ok, _reg} = Mob.Test.ProcessHelpers.ensure_component_registry()
      :ok
    end

    test "a tree another process expanded passes through: its component isn't started again" do
      owner = self()
      id = :"owned_#{System.unique_integer([:positive])}"

      tree = %{
        type: :column,
        props: %{},
        children: [Mob.UI.native_view(CounterComponent, id: id, initial: 4)]
      }

      {expanded, active} = Mob.Component.expand(tree, owner, :no_render)
      assert MapSet.equal?(active, MapSet.new([{id, CounterComponent}]))

      assert [%{type: :native_view, props: %{count: 4, id: id_string, component_handle: _}}] =
               expanded.children

      assert id_string == Atom.to_string(id)
      {:ok, component} = Mob.ComponentRegistry.lookup(owner, id, CounterComponent)

      # The screen that draws the owner's tree.
      screen = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(screen, :kill) end)
      assert {^expanded, empty} = Mob.Component.expand(expanded, screen, :no_render)
      assert MapSet.size(empty) == 0
      assert {:error, :not_found} = Mob.ComponentRegistry.lookup(screen, id, CounterComponent)
      assert {:ok, ^component} = Mob.ComponentRegistry.lookup(owner, id, CounterComponent)
    end
  end

  # ── Mob.ComponentRegistry ─────────────────────────────────────────────────

  describe "Mob.ComponentRegistry" do
    setup do
      # Mob.ComponentRegistry registers under a fixed global name, and the run
      # owns it (test_helper.exs starts it) rather than whichever async file
      # got there first. Take the pid from the helper: a separate
      # Process.whereis/1 here would be the same check-then-act this module
      # exists to remove, and would hand back nil if anything stopped the
      # registry in between.
      {:ok, reg} = Mob.Test.ProcessHelpers.ensure_component_registry()

      {:ok, reg: reg}
    end

    test "register and lookup succeed" do
      screen = self()
      Mob.ComponentRegistry.register(screen, :my_chart, CounterComponent, self())
      assert {:ok, _pid} = Mob.ComponentRegistry.lookup(screen, :my_chart, CounterComponent)
    end

    test "lookup returns :not_found for unknown key" do
      assert {:error, :not_found} =
               Mob.ComponentRegistry.lookup(self(), :missing, CounterComponent)
    end

    test "deregister removes the entry" do
      screen = self()
      Mob.ComponentRegistry.register(screen, :temp, CounterComponent, self())
      Mob.ComponentRegistry.deregister(screen, :temp, CounterComponent, self())

      assert {:error, :not_found} =
               Mob.ComponentRegistry.lookup(screen, :temp, CounterComponent)
    end

    test "duplicate id raises" do
      screen = self()
      Mob.ComponentRegistry.register(screen, :dupe, CounterComponent, self())

      assert_raise ArgumentError, ~r/duplicate id/, fn ->
        Mob.ComponentRegistry.register(screen, :dupe, CounterComponent, spawn(fn -> nil end))
      end
    end
  end
end
