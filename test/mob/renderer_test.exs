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
  end
end
