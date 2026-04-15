defmodule Mob.RendererTest do
  use ExUnit.Case, async: false

  alias Mob.Renderer

  # A mock NIF backend that records calls instead of touching Android.
  defmodule MockNIF do
    use Agent

    # Use Agent.start (not start_link) so the Agent is not linked to the test
    # process and survives across test process boundaries. The setup resets state
    # rather than restarting the process, eliminating name-registry races.
    def start_link, do: Agent.start(fn -> %{calls: [], tap_next: 0} end, name: __MODULE__)

    def calls,  do: Agent.get(__MODULE__, & &1.calls)
    def reset,  do: Agent.update(__MODULE__, fn _ -> %{calls: [], tap_next: 0} end)

    def clear_taps do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:clear_taps, []} | s.calls], tap_next: 0} end)
      :ok
    end

    def set_transition(trans) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:set_transition, [trans]} | s.calls]} end)
      :ok
    end

    def register_tap(pid_or_tagged) do
      Agent.get_and_update(__MODULE__, fn s ->
        handle = s.tap_next
        calls  = [{:register_tap, [pid_or_tagged]} | s.calls]
        {handle, %{s | calls: calls, tap_next: handle + 1}}
      end)
    end

    def set_root(json) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:set_root, [json]} | s.calls]} end)
      :ok
    end
  end

  setup do
    # Start the Agent if not running, or just reset state if already running.
    # Using Agent.start (not start_link) means it persists across test processes.
    case Process.whereis(MockNIF) do
      nil -> {:ok, _} = MockNIF.start_link()
      _   -> MockNIF.reset()
    end

    :ok
  end

  describe "render/3" do
    test "calls clear_taps before serializing" do
      tree = %{type: :column, props: %{}, children: []}
      Renderer.render(tree, :android, MockNIF)
      assert Enum.any?(MockNIF.calls(), fn {f, _} -> f == :clear_taps end)
    end

    test "calls set_root with a JSON binary" do
      tree = %{type: :column, props: %{}, children: []}
      Renderer.render(tree, :android, MockNIF)
      assert Enum.any?(MockNIF.calls(), fn
        {:set_root, [json]} -> is_binary(json)
        _ -> false
      end)
    end

    test "returns {:ok, :json_tree}" do
      tree = %{type: :column, props: %{}, children: []}
      assert {:ok, :json_tree} = Renderer.render(tree, :android, MockNIF)
    end

    test "JSON contains correct node type" do
      tree = %{type: :text, props: %{text: "Hello"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["type"] == "text"
    end

    test "JSON contains text prop" do
      tree = %{type: :text, props: %{text: "Hello"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text"] == "Hello"
    end

    test "JSON contains nested children" do
      tree = %{
        type: :column,
        props: %{},
        children: [
          %{type: :text, props: %{text: "A"}, children: []},
          %{type: :text, props: %{text: "B"}, children: []}
        ]
      }
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert length(decoded["children"]) == 2
      assert Enum.at(decoded["children"], 0)["props"]["text"] == "A"
      assert Enum.at(decoded["children"], 1)["props"]["text"] == "B"
    end

    test "on_tap pid is replaced by integer handle" do
      pid  = self()
      tree = %{type: :button, props: %{text: "Tap", on_tap: pid}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_tap"])
    end

    test "register_tap is called for each on_tap pid" do
      pid  = self()
      tree = %{
        type: :column,
        props: %{},
        children: [
          %{type: :button, props: %{text: "A", on_tap: pid}, children: []},
          %{type: :button, props: %{text: "B", on_tap: pid}, children: []}
        ]
      }
      Renderer.render(tree, :android, MockNIF)
      tap_calls = Enum.filter(MockNIF.calls(), fn {f, _} -> f == :register_tap end)
      assert length(tap_calls) == 2
    end

    test "on_tap {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :button, props: %{text: "Tap", on_tap: {pid, :my_action}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_tap"])
    end

    test "on_change {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :text_field, props: %{value: "hi", on_change: {pid, :name}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_change"])
    end

    test "on_focus {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :text_field, props: %{value: "hi", on_focus: {pid, :name_focused}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_focus"])
    end

    test "on_blur {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :text_field, props: %{value: "hi", on_blur: {pid, :name_blurred}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_blur"])
    end

    test "on_submit {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :text_field, props: %{value: "hi", on_submit: {pid, :name_submitted}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_submit"])
    end

    test "keyboard atom is serialised as string" do
      tree = %{type: :text_field, props: %{value: "", keyboard: :decimal}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["keyboard"] == "decimal"
    end

    test "return_key atom is serialised as string" do
      tree = %{type: :text_field, props: %{value: "", return_key: :next}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["return_key"] == "next"
    end

    test "register_tap receives {pid, tag} for tagged taps" do
      pid  = self()
      tree = %{type: :button, props: %{text: "Tap", on_tap: {pid, :my_action}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      tap_calls = Enum.filter(MockNIF.calls(), fn {f, _} -> f == :register_tap end)
      assert [{:register_tap, [{^pid, :my_action}]}] = tap_calls
    end

    test "padding prop is serialized into JSON" do
      tree = %{type: :column, props: %{padding: 16}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["padding"] == 16
    end

    test "background color integer is preserved in JSON" do
      tree = %{type: :column, props: %{background: 0xFFFFFFFF}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["background"] == 0xFFFFFFFF
    end

    test "on_end_reached {pid, tag} is replaced by integer handle" do
      pid  = self()
      tree = %{type: :lazy_list, props: %{on_end_reached: {pid, :load_more}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_end_reached"])
    end

    test "image src prop is serialized as string" do
      tree = %{type: :image, props: %{src: "https://example.com/photo.jpg"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["src"] == "https://example.com/photo.jpg"
    end

    test "placeholder_color atom is resolved to ARGB integer" do
      tree = %{type: :image, props: %{src: "https://example.com/photo.jpg", placeholder_color: :gray_200}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["placeholder_color"] == 0xFFEEEEEE
    end
  end

  describe "style token resolution" do
    test "color atom in background is resolved to ARGB integer" do
      tree = %{type: :column, props: %{background: :primary}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["background"] == 0xFF2196F3
    end

    test "color atom in text_color is resolved" do
      tree = %{type: :text, props: %{text: "hi", text_color: :on_surface}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_color"] == 0xFF212121
    end

    test "text_size atom is resolved to float sp" do
      tree = %{type: :text, props: %{text: "hi", text_size: :xl}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_size"] == 20.0
    end

    test "unknown color atom is left as-is (serialised as string)" do
      tree = %{type: :column, props: %{background: :not_a_real_color}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["background"] == "not_a_real_color"
    end
  end

  describe "platform blocks" do
    test "android block is merged on android platform" do
      tree = %{type: :column, props: %{padding: 8, android: %{padding: 16}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["padding"] == 16
    end

    test "ios block is merged on ios platform" do
      tree = %{type: :column, props: %{padding: 8, ios: %{padding: 20}}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["padding"] == 20
    end

    test "ios block is ignored on android platform" do
      tree = %{type: :column, props: %{padding: 8, ios: %{padding: 20}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["padding"] == 8
      refute Map.has_key?(decoded["props"], "ios")
    end

    test "platform keys are stripped from serialised JSON" do
      tree = %{type: :column, props: %{android: %{padding: 8}, ios: %{padding: 20}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      refute Map.has_key?(decoded["props"], "android")
      refute Map.has_key?(decoded["props"], "ios")
    end
  end

  describe "Mob.Style struct" do
    test "style props are merged into node props" do
      style = %Mob.Style{props: %{text_size: :xl, text_color: :white}}
      tree  = %{type: :text, props: %{text: "hi", style: style}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_size"] == 20.0
      assert decoded["props"]["text_color"] == 0xFFFFFFFF
    end

    test "inline props override style props" do
      style = %Mob.Style{props: %{text_size: :xl, text_color: :white}}
      tree  = %{type: :text, props: %{text: "hi", style: style, text_size: :sm}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_size"] == 14.0
    end

    test "style key is not present in serialised JSON" do
      style = %Mob.Style{props: %{text_size: :base}}
      tree  = %{type: :text, props: %{text: "hi", style: style}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      refute Map.has_key?(decoded["props"], "style")
    end
  end
end
