defmodule Mob.ListTest do
  use ExUnit.Case, async: true

  alias Mob.List

  describe "default_renderer/1" do
    test "renders a binary as a text row" do
      node = List.default_renderer("Hello")
      assert node.type == :text
      assert node.props.text == "Hello"
    end

    test "renders a map with :label" do
      node = List.default_renderer(%{label: "World"})
      assert node.props.text == "World"
    end

    test "renders a map with :text" do
      node = List.default_renderer(%{text: "Foo"})
      assert node.props.text == "Foo"
    end

    test "falls back to inspect for unknown values" do
      node = List.default_renderer({:some, :tuple})
      assert node.props.text == inspect({:some, :tuple})
    end
  end

  describe "put_renderer/3" do
    test "stores the renderer in socket.__mob__" do
      socket = Mob.Socket.new(Mob.ListTest)
      renderer = fn item -> %{type: :text, props: %{text: item}, children: []} end
      socket = List.put_renderer(socket, :my_list, renderer)
      assert Map.get(socket.__mob__, :list_renderers) == %{my_list: renderer}
    end

    test "preserves existing renderers" do
      socket = Mob.Socket.new(Mob.ListTest)
      r1 = fn item -> %{type: :text, props: %{text: item}, children: []} end
      r2 = fn item -> %{type: :text, props: %{text: to_string(item)}, children: []} end
      socket = socket |> List.put_renderer(:list_a, r1) |> List.put_renderer(:list_b, r2)
      renderers = Map.get(socket.__mob__, :list_renderers)
      assert renderers[:list_a] == r1
      assert renderers[:list_b] == r2
    end
  end

  describe "expand/3" do
    test "leaves non-list nodes unchanged" do
      pid = self()
      node = %{type: :text, props: %{text: "hi"}, children: []}
      assert List.expand(node, %{}, pid) == node
    end

    test "expands :list node into :lazy_list with default renderer" do
      pid = self()

      node = %{
        type: :list,
        props: %{id: :my_list, items: ["a", "b"]},
        children: []
      }

      expanded = List.expand(node, %{}, pid)

      assert expanded.type == :lazy_list
      assert length(expanded.children) == 2
    end

    test "each row is a :box wrapping the rendered item" do
      pid = self()

      node = %{
        type: :list,
        props: %{id: :my_list, items: ["x"]},
        children: []
      }

      [row] = List.expand(node, %{}, pid).children

      assert row.type == :box
      assert row.props.on_tap == {pid, {:list, :my_list, :select, 0}}
      assert hd(row.children).type == :text
      assert hd(row.children).props.text == "x"
    end

    test "uses custom renderer when registered" do
      pid = self()

      renderer = fn item ->
        %{type: :text, props: %{text: "custom:#{item}"}, children: []}
      end

      node = %{
        type: :list,
        props: %{id: :my_list, items: ["a"]},
        children: []
      }

      [row] = List.expand(node, %{my_list: renderer}, pid).children
      assert hd(row.children).props.text == "custom:a"
    end

    test "on_end_reached prop passes through to lazy_list" do
      pid = self()

      node = %{
        type: :list,
        props: %{id: :my_list, items: [], on_end_reached: {pid, :load_more}},
        children: []
      }

      expanded = List.expand(node, %{}, pid)
      assert expanded.props.on_end_reached == {pid, :load_more}
      refute Map.has_key?(expanded.props, :id)
      refute Map.has_key?(expanded.props, :items)
    end

    test "recurses into children of non-list nodes" do
      pid = self()

      node = %{
        type: :column,
        props: %{},
        children: [
          %{type: :list, props: %{id: :inner, items: ["z"]}, children: []}
        ]
      }

      expanded = List.expand(node, %{}, pid)
      assert expanded.type == :column
      [child] = expanded.children
      assert child.type == :lazy_list
    end
  end

  describe "list events via Mob.Screen" do
    defmodule ListScreen do
      use Mob.Screen

      def mount(_params, _session, socket) do
        socket =
          socket
          |> Mob.Socket.assign(:items, ["alpha", "beta", "gamma"])
          |> Mob.Socket.assign(:selected, nil)

        {:ok, socket}
      end

      def render(assigns) do
        %{
          type: :list,
          props: %{id: :my_list, items: assigns.items},
          children: []
        }
      end

      def handle_info({:select, :my_list, index}, socket) do
        item = Enum.at(socket.assigns.items, index)
        {:noreply, Mob.Socket.assign(socket, :selected, item)}
      end
    end

    test "select event is delivered as {:select, id, index}" do
      {:ok, pid} = Mob.Screen.start_link(ListScreen, %{})
      send(pid, {:tap, {:list, :my_list, :select, 1}})
      :timer.sleep(50)
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.selected == "beta"
    end

    test "select event with index 0 works" do
      {:ok, pid} = Mob.Screen.start_link(ListScreen, %{})
      send(pid, {:tap, {:list, :my_list, :select, 0}})
      :timer.sleep(50)
      socket = Mob.Screen.get_socket(pid)
      assert socket.assigns.selected == "alpha"
    end
  end
end
