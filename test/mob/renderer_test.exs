defmodule Mob.RendererTest do
  use ExUnit.Case, async: true

  alias Mob.Renderer

  # A mock NIF backend that records calls instead of touching Android Views.
  # This lets us test the renderer logic without a device.
  defmodule MockNIF do
    use Agent

    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def calls, do: Agent.get(__MODULE__, & &1)

    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    # Stub every NIF function — return a fake view ref and record the call.
    def create_column, do: record(:create_column, [])
    def create_row, do: record(:create_row, [])
    def create_label(text), do: record(:create_label, [text])
    def create_button(text), do: record(:create_button, [text])
    def create_scroll, do: record(:create_scroll, [])
    def add_child(parent, child, is_row), do: (record_void(:add_child, [parent, child, is_row]); :ok)
    def set_text(view, text), do: (record_void(:set_text, [view, text]); :ok)
    def set_text_size(view, sp), do: (record_void(:set_text_size, [view, sp]); :ok)
    def set_text_color(view, color), do: (record_void(:set_text_color, [view, color]); :ok)
    def set_background_color(view, color), do: (record_void(:set_background_color, [view, color]); :ok)
    def set_padding(view, dp), do: (record_void(:set_padding, [view, dp]); :ok)
    def on_tap(view, pid), do: (record_void(:on_tap, [view, pid]); :ok)
    def set_root(view), do: (record_void(:set_root, [view]); :ok)

    defp record(fn_name, args) do
      ref = make_ref()
      Agent.update(__MODULE__, fn calls -> [{fn_name, args, ref} | calls] end)
      {:ok, ref}
    end

    defp record_void(fn_name, args) do
      Agent.update(__MODULE__, fn calls -> [{fn_name, args} | calls] end)
    end
  end

  setup do
    MockNIF.start_link()
    MockNIF.reset()
    :ok
  end

  describe "render/3" do
    test "column with no children calls create_column" do
      tree = %{type: :column, props: %{}, children: []}
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      assert Enum.any?(calls, fn {fn_name, _, _} -> fn_name == :create_column end)
    end

    test "text node calls create_label with correct text" do
      tree = %{type: :text, props: %{text: "Hello"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      assert Enum.any?(calls, fn
        {:create_label, ["Hello"], _} -> true
        _ -> false
      end)
    end

    test "button node calls create_button with label" do
      tree = %{type: :button, props: %{label: "Click me"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      assert Enum.any?(calls, fn
        {:create_button, ["Click me"], _} -> true
        _ -> false
      end)
    end

    test "column with children calls add_child for each child" do
      tree = %{
        type: :column,
        props: %{},
        children: [
          %{type: :text, props: %{text: "A"}, children: []},
          %{type: :text, props: %{text: "B"}, children: []}
        ]
      }
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      add_child_calls = Enum.filter(calls, fn
        {:add_child, _} -> true
        _ -> false
      end)
      assert length(add_child_calls) == 2
    end

    test "returns a view ref for the root node" do
      tree = %{type: :column, props: %{}, children: []}
      assert {:ok, ref} = Renderer.render(tree, :android, MockNIF)
      assert is_reference(ref)
    end

    test "padding prop triggers set_padding call" do
      tree = %{type: :column, props: %{padding: 16}, children: []}
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      assert Enum.any?(calls, fn
        {:set_padding, _} -> true
        _ -> false
      end)
    end

    test "background prop triggers set_background_color call" do
      tree = %{type: :column, props: %{background: 0xFFFFFFFF}, children: []}
      Renderer.render(tree, :android, MockNIF)
      calls = MockNIF.calls()
      assert Enum.any?(calls, fn
        {:set_background_color, _} -> true
        _ -> false
      end)
    end
  end
end
