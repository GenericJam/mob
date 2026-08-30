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

  # ── Mob.ComponentRegistry ─────────────────────────────────────────────────

  describe "Mob.ComponentRegistry" do
    setup do
      # Mob.ComponentRegistry registers under a fixed global name. Another
      # async test file (component_server_test.exs) may have already started
      # it — start_supervised/1 returns {:error, {:already_started, _}} in
      # that case rather than raising, so tolerate either order instead of
      # racing to be first (MOB-98: this is the shared-name race that fix
      # already covers on that file's side; this file needed the same
      # tolerance).
      reg =
        case start_supervised({Mob.ComponentRegistry, []}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

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
