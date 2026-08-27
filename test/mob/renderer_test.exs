defmodule Mob.RendererTest do
  use ExUnit.Case, async: false

  alias Mob.Renderer

  # A mock NIF backend that records calls instead of touching Android.
  defmodule MockNIF do
    use Agent

    # Use Agent.start (not start_link) so the Agent is not linked to the test
    # process and survives across test process boundaries. The setup resets state
    # rather than restarting the process, eliminating name-registry races.
    def start_link,
      do:
        Agent.start(fn -> %{calls: [], tap_next: 0, tap_result: :allocate} end, name: __MODULE__)

    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def reset,
      do: Agent.update(__MODULE__, fn _ -> %{calls: [], tap_next: 0, tap_result: :allocate} end)

    # :exhausted simulates a full MAX_TAP_HANDLES pool (MOB-100 follow-up) —
    # both native sides now return the -1 "unhandled" sentinel instead of
    # badarg when the pool is full, since every mob_send_* sender already
    # no-ops on an out-of-range handle.
    def set_tap_result(result), do: Agent.update(__MODULE__, &%{&1 | tap_result: result})

    def clear_taps do
      Agent.update(__MODULE__, fn s ->
        %{s | calls: [{:clear_taps, []} | s.calls], tap_next: 0}
      end)

      :ok
    end

    def set_transition(trans) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:set_transition, [trans]} | s.calls]} end)
      :ok
    end

    def register_tap(pid_or_tagged) do
      Agent.get_and_update(__MODULE__, fn s ->
        calls = [{:register_tap, [pid_or_tagged]} | s.calls]

        case s.tap_result do
          :allocate -> {s.tap_next, %{s | calls: calls, tap_next: s.tap_next + 1}}
          :exhausted -> {-1, %{s | calls: calls}}
        end
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
      _ -> MockNIF.reset()
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

    test "a plugin:// image src resolves to its bundle path" do
      Mob.Plugins.install_asset_root("/bundle/priv/generated/plugin_assets")
      on_exit(fn -> Mob.Plugins.install_asset_root("") end)
      tree = %{type: :image, props: %{src: "plugin://kv/icon.png"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)

      assert decoded["props"]["src"] ==
               "/bundle/priv/generated/plugin_assets/assets/plugin/kv/icon.png"
    end

    test "an unresolvable plugin:// image src passes through unchanged (asset root not cached)" do
      tree = %{type: :image, props: %{src: "plugin://kv/icon.png"}, children: []}

      ExUnit.CaptureLog.capture_log(fn ->
        Renderer.render(tree, :android, MockNIF)
      end)

      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["src"] == "plugin://kv/icon.png"
    end

    test "a non-plugin image src is left untouched" do
      tree = %{type: :image, props: %{src: "https://x/y.png"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["src"] == "https://x/y.png"
    end

    test "on_tap pid is replaced by integer handle" do
      pid = self()
      tree = %{type: :button, props: %{text: "Tap", on_tap: pid}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_tap"])
    end

    test "an exhausted tap pool (-1 sentinel) renders instead of crashing (MOB-100 follow-up)" do
      MockNIF.set_tap_result(:exhausted)

      tree = %{
        type: :column,
        props: %{},
        children: [
          %{type: :button, props: %{text: "A", on_tap: self()}, children: []},
          %{type: :text_field, props: %{id: "f", on_change: {self(), :changed}}, children: []}
        ]
      }

      assert {:ok, :json_tree} = Renderer.render(tree, :android, MockNIF)

      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      [button, field] = decoded["children"]
      assert button["props"]["on_tap"] == -1
      assert field["props"]["on_change"] == -1
    end

    test "register_tap is called for each on_tap pid" do
      pid = self()

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
      pid = self()
      tree = %{type: :button, props: %{text: "Tap", on_tap: {pid, :my_action}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_tap"])
    end

    test "on_drag {pid, tag} is replaced by integer handle" do
      pid = self()
      tree = %{type: :canvas, props: %{on_drag: {pid, :draw}}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_drag"])
    end

    test "register_tap is called for an on_drag handle" do
      pid = self()
      tree = %{type: :canvas, props: %{on_drag: {pid, :draw}}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      assert Enum.any?(MockNIF.calls(), fn {f, _} -> f == :register_tap end)
    end

    test "on_change {pid, tag} is replaced by integer handle" do
      pid = self()
      tree = %{type: :text_field, props: %{value: "hi", on_change: {pid, :name}}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_change"])
    end

    test "on_focus {pid, tag} is replaced by integer handle" do
      pid = self()

      tree = %{
        type: :text_field,
        props: %{value: "hi", on_focus: {pid, :name_focused}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_focus"])
    end

    test "on_blur {pid, tag} is replaced by integer handle" do
      pid = self()

      tree = %{
        type: :text_field,
        props: %{value: "hi", on_blur: {pid, :name_blurred}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_blur"])
    end

    test "on_submit {pid, tag} is replaced by integer handle" do
      pid = self()

      tree = %{
        type: :text_field,
        props: %{value: "hi", on_submit: {pid, :name_submitted}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_submit"])
    end

    test "on_compose {pid, tag} is replaced by integer handle (IME composition)" do
      pid = self()

      tree = %{
        type: :text_field,
        props: %{value: "", on_compose: {pid, :ime}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_compose"])
    end

    # ── Batch 3: on_select ────────────────────────────────────────────────
    test "on_select {pid, tag} is replaced by integer handle" do
      pid = self()
      tree = %{type: :picker, props: %{on_select: {pid, :picked}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_select"])
    end

    # ── Batch 4: gestures ─────────────────────────────────────────────────
    test "on_long_press {pid, tag} is replaced by integer handle" do
      pid = self()
      tree = %{type: :button, props: %{on_long_press: {pid, :menu}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_long_press"])
    end

    test "on_double_tap {pid, tag} is replaced by integer handle" do
      pid = self()
      tree = %{type: :button, props: %{on_double_tap: {pid, :zoom}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_double_tap"])
    end

    test "on_swipe and directional swipes are replaced by integer handles" do
      pid = self()

      tree = %{
        type: :card,
        props: %{
          on_swipe: {pid, :any},
          on_swipe_left: {pid, :delete},
          on_swipe_right: {pid, :archive},
          on_swipe_up: {pid, :reveal},
          on_swipe_down: {pid, :collapse}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_swipe"])
      assert is_integer(decoded["props"]["on_swipe_left"])
      assert is_integer(decoded["props"]["on_swipe_right"])
      assert is_integer(decoded["props"]["on_swipe_up"])
      assert is_integer(decoded["props"]["on_swipe_down"])
    end

    test "register_tap is called once per gesture prop" do
      pid = self()

      tree = %{
        type: :card,
        props: %{
          on_tap: {pid, :tap},
          on_long_press: {pid, :long},
          on_double_tap: {pid, :double},
          on_swipe_left: {pid, :left}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      tap_calls = Enum.filter(MockNIF.calls(), fn {f, _} -> f == :register_tap end)
      assert length(tap_calls) == 4
    end

    test "gesture tags must be {pid, tag} — bare pid is rejected at serialisation" do
      # Gestures intentionally require a {pid, tag} shape. A bare pid falls
      # through to the generic catch-all clause and crashes JSON encoding
      # because pids aren't serialisable. This documents the contract: gesture
      # props must always be tagged.
      pid = self()
      tree = %{type: :button, props: %{on_long_press: pid}, children: []}

      assert_raise ErlangError, ~r/unsupported_type/, fn ->
        Renderer.render(tree, :android, MockNIF)
      end
    end

    # ── Batch 5 Tier 1: high-frequency events with throttle config ────────
    test "on_scroll without opts uses default throttle (no scroll_config emitted)" do
      pid = self()
      tree = %{type: :scroll, props: %{on_scroll: {pid, :main}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_scroll"])
      # Default config not emitted; native side uses Mob.Event.Throttle.default_for(:scroll)
      refute Map.has_key?(decoded["props"], "scroll_config")
    end

    test "on_scroll with throttle opts emits scroll_config" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{on_scroll: {pid, :main, throttle: 100}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert is_integer(decoded["props"]["on_scroll"])
      cfg = decoded["props"]["scroll_config"]
      assert cfg["throttle_ms"] == 100
      assert cfg["delta_threshold"] == 1
      assert cfg["leading"] == true
      assert cfg["trailing"] == true
    end

    test "on_scroll with throttle: 0 (raw firing rate) is valid" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{on_scroll: {pid, :main, throttle: 0, delta: 0}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["scroll_config"]["throttle_ms"] == 0
      assert decoded["props"]["scroll_config"]["delta_threshold"] == 0
    end

    test "on_scroll with debounce opts" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{on_scroll: {pid, :main, debounce: 200}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["scroll_config"]["debounce_ms"] == 200
      # Throttle default still applies:
      assert decoded["props"]["scroll_config"]["throttle_ms"] == 33
    end

    test "on_drag, on_pinch, on_rotate, on_pointer_move all accept throttle opts" do
      pid = self()

      tree = %{
        type: :container,
        props: %{
          on_drag: {pid, :pan, throttle: 16},
          on_pinch: {pid, :zoom, throttle: 16, delta: 0.05},
          on_rotate: {pid, :twist, throttle: 16},
          on_pointer_move: {pid, :hover, throttle: 50, delta: 8}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      props = :json.decode(json)["props"]

      assert is_integer(props["on_drag"])
      assert props["drag_config"]["throttle_ms"] == 16
      assert is_integer(props["on_pinch"])
      assert props["pinch_config"]["delta_threshold"] == 0.05
      assert is_integer(props["on_rotate"])
      assert is_integer(props["on_pointer_move"])
      assert props["pointer_config"]["delta_threshold"] == 8
    end

    test "throttle: invalid value raises during render" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{on_scroll: {pid, :main, throttle: -1}},
        children: []
      }

      assert_raise ArgumentError, ~r/throttle/, fn ->
        Renderer.render(tree, :android, MockNIF)
      end
    end

    # ── Batch 5 Tier 2: semantic scroll events ────────────────────────────
    test "on_scroll_began, on_scroll_ended, on_scroll_settled get handles" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{
          on_scroll_began: {pid, :s_began},
          on_scroll_ended: {pid, :s_ended},
          on_scroll_settled: {pid, :s_settled}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      props = :json.decode(json)["props"]
      assert is_integer(props["on_scroll_began"])
      assert is_integer(props["on_scroll_ended"])
      assert is_integer(props["on_scroll_settled"])
    end

    test "on_top_reached gets a handle" do
      pid = self()
      tree = %{type: :scroll, props: %{on_top_reached: {pid, :hit_top}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert is_integer(:json.decode(json)["props"]["on_top_reached"])
    end

    test "on_scrolled_past requires a threshold and emits both handle + threshold" do
      pid = self()

      tree = %{
        type: :scroll,
        props: %{on_scrolled_past: {pid, :crossed_100, 100}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      props = :json.decode(json)["props"]
      assert is_integer(props["on_scrolled_past"])
      assert props["scrolled_past_threshold"] == 100
    end

    test "on_scrolled_past supports float thresholds" do
      pid = self()
      tree = %{type: :scroll, props: %{on_scrolled_past: {pid, :tag, 250.5}}, children: []}

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["scrolled_past_threshold"] == 250.5
    end

    # ── Batch 5 Tier 3: native-side scroll-driven UI ──────────────────────
    test "parallax config passes through with stringified atoms" do
      tree = %{
        type: :image,
        props: %{
          src: "hero.jpg",
          parallax: %{ratio: 0.5, container: :main_scroll}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      cfg = :json.decode(json)["props"]["parallax"]
      assert cfg["ratio"] == 0.5
      assert cfg["container"] == "main_scroll"
    end

    test "fade_on_scroll config" do
      tree = %{
        type: :navbar,
        props: %{
          fade_on_scroll: %{container: :main, fade_after: 100, fade_over: 60}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      cfg = :json.decode(json)["props"]["fade_on_scroll"]
      assert cfg["container"] == "main"
      assert cfg["fade_after"] == 100
      assert cfg["fade_over"] == 60
    end

    test "sticky_when_scrolled_past config" do
      tree = %{
        type: :header,
        props: %{
          sticky_when_scrolled_past: %{container: :feed, threshold: 200}
        },
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      cfg = :json.decode(json)["props"]["sticky_when_scrolled_past"]
      assert cfg["container"] == "feed"
      assert cfg["threshold"] == 200
    end

    test "Tier 3 props do NOT register taps (no BEAM round-trip)" do
      tree = %{
        type: :image,
        props: %{parallax: %{ratio: 0.5, container: :main}},
        children: []
      }

      Renderer.render(tree, :android, MockNIF)
      tap_calls = Enum.filter(MockNIF.calls(), fn {f, _} -> f == :register_tap end)
      assert tap_calls == []
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

    test "secure boolean is passed through unchanged" do
      tree = %{type: :text_field, props: %{value: "", secure: true}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["secure"] == true
    end

    test "secure defaults to absent when unset" do
      tree = %{type: :text_field, props: %{value: ""}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      refute Map.has_key?(decoded["props"], "secure")
    end

    test "register_tap receives {pid, tag} for tagged taps" do
      pid = self()
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
      pid = self()
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
      tree = %{
        type: :image,
        props: %{src: "https://example.com/photo.jpg", placeholder_color: :gray_200},
        children: []
      }

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
      # :on_surface resolves through the default dark theme → :gray_100 → 0xFFF5F5F5
      tree = %{type: :text, props: %{text: "hi", text_color: :on_surface}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_color"] == 0xFFF5F5F5
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

  describe "theme token resolution" do
    setup do
      # Reset to default theme after each test
      on_exit(fn -> Application.delete_env(:mob, :theme) end)
      :ok
    end

    test "spacing token :space_md resolves to 16 at default scale" do
      tree = %{type: :column, props: %{padding: :space_md}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["padding"] == 16
    end

    test "spacing token scales with space_scale" do
      Mob.Theme.set(space_scale: 2.0)
      tree = %{type: :column, props: %{padding: :space_md}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["padding"] == 32
    end

    test "radius token :radius_md resolves to theme value" do
      tree = %{type: :button, props: %{text: "x", corner_radius: :radius_md}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["corner_radius"] == 10
    end

    test "radius token reflects custom theme radius" do
      Mob.Theme.set(radius_md: 20)
      tree = %{type: :button, props: %{text: "x", corner_radius: :radius_md}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["corner_radius"] == 20
    end

    test "text_size scales with type_scale" do
      Mob.Theme.set(type_scale: 2.0)
      tree = %{type: :text, props: %{text: "hi", text_size: :base}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["text_size"] == 32.0
    end

    test "semantic color :primary resolves through theme to palette integer" do
      Mob.Theme.set(primary: :emerald_500)
      tree = %{type: :column, props: %{background: :primary}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["background"] == 0xFF10B981
    end

    test "semantic color accepts raw ARGB integer in theme" do
      Mob.Theme.set(primary: 0xFFDEADBEEF)
      tree = %{type: :column, props: %{background: :primary}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["background"] == 0xFFDEADBEEF
    end

    test "button gets default background from theme when not specified" do
      tree = %{type: :button, props: %{text: "Go"}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      props = :json.decode(json)["props"]
      # Default primary → blue_500 → 0xFF2196F3
      assert props["background"] == 0xFF2196F3
    end

    test "explicit button background overrides default" do
      tree = %{type: :button, props: %{text: "Go", background: :red_500}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["props"]["background"] == 0xFFF44336
    end

    test "divider gets default color from theme border token" do
      tree = %{type: :divider, props: %{}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      # default border → :gray_700 → 0xFF616161
      assert :json.decode(json)["props"]["color"] == 0xFF616161
    end
  end

  # ── Component type name serialization ────────────────────────────────────
  # The renderer converts atom types to strings via Atom.to_string/1.
  # Multi-word types (PascalCase in the native layer, snake_case in Elixir) are
  # the risky ones: a mismatch between "web_view" and "webview" causes a silent
  # white-screen. Each test below pins the exact string the native layer must match.

  describe "component type name serialization" do
    defp rendered_type(type) do
      tree = %{type: type, props: %{}, children: []}
      MockNIF.reset()
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      :json.decode(json)["type"]
    end

    # Single-word types — baseline sanity
    test "text → \"text\"", do: assert(rendered_type(:text) == "text")
    test "button → \"button\"", do: assert(rendered_type(:button) == "button")
    test "column → \"column\"", do: assert(rendered_type(:column) == "column")
    test "row → \"row\"", do: assert(rendered_type(:row) == "row")
    test "image → \"image\"", do: assert(rendered_type(:image) == "image")
    test "scroll → \"scroll\"", do: assert(rendered_type(:scroll) == "scroll")

    # Multi-word types — the ones where a missing underscore causes a white screen
    test "web_view → \"web_view\" (not \"webview\")" do
      assert rendered_type(:web_view) == "web_view"
    end

    test "camera_preview → \"camera_preview\"" do
      assert rendered_type(:camera_preview) == "camera_preview"
    end

    test "lazy_list → \"lazy_list\"" do
      assert rendered_type(:lazy_list) == "lazy_list"
    end

    test "tab_bar → \"tab_bar\"" do
      assert rendered_type(:tab_bar) == "tab_bar"
    end

    test "text_field → \"text_field\"" do
      assert rendered_type(:text_field) == "text_field"
    end

    test "native_view → \"native_view\"" do
      assert rendered_type(:native_view) == "native_view"
    end

    # Mob.UI constructors — verify the constructor atom matches the expected string
    test "Mob.UI.webview/1 produces type \"web_view\"" do
      node = Mob.UI.webview(url: "https://example.com")
      MockNIF.reset()
      Renderer.render(node, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["type"] == "web_view"
    end

    test "Mob.UI.camera_preview/1 produces type \"camera_preview\"" do
      node = Mob.UI.camera_preview(facing: :back)
      MockNIF.reset()
      Renderer.render(node, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["type"] == "camera_preview"
    end

    test "Mob.UI.native_view/2 produces type \"native_view\"" do
      node = Mob.UI.native_view(MyApp.FakeComponent, id: :chart)
      MockNIF.reset()
      Renderer.render(node, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["type"] == "native_view"
    end
  end

  describe "Mob.Style struct" do
    test "style props are merged into node props" do
      style = %Mob.Style{props: %{text_size: :xl, text_color: :white}}
      tree = %{type: :text, props: %{text: "hi", style: style}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_size"] == 20.0
      assert decoded["props"]["text_color"] == 0xFFFFFFFF
    end

    test "inline props override style props" do
      style = %Mob.Style{props: %{text_size: :xl, text_color: :white}}
      tree = %{type: :text, props: %{text: "hi", style: style, text_size: :sm}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      assert decoded["props"]["text_size"] == 14.0
    end

    test "style key is not present in serialised JSON" do
      style = %Mob.Style{props: %{text_size: :base}}
      tree = %{type: :text, props: %{text: "hi", style: style}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      decoded = :json.decode(json)
      refute Map.has_key?(decoded["props"], "style")
    end
  end

  # ── Canvas draw-op encoding ──────────────────────────────────────────────
  # Canvas's `:draw` prop is a list of op maps, each potentially with an atom
  # `:color` token that needs the same theme/palette resolution as top-level
  # color props. These tests pin the wire shape AND the resolution behavior.

  describe "canvas draw-op encoding" do
    setup do
      # Two tests in this describe call `Mob.Theme.set(primary: :emerald_500)`
      # to verify draw-op token resolution. Without an on_exit reset the
      # mutated theme persisted into later tests (e.g. the "style token
      # resolution" describe's `assert background == 0xFF2196F3` started
      # asserting against whatever color the theme leaked).
      on_exit(fn -> Application.delete_env(:mob, :theme) end)
      :ok
    end

    defp canvas_draw(ops) do
      tree = %{type: :canvas, props: %{width: 100, height: 100, draw: ops}, children: []}
      MockNIF.reset()
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      :json.decode(json)["props"]["draw"]
    end

    test "type :canvas serializes as the string \"canvas\"" do
      tree = %{type: :canvas, props: %{width: 100, height: 100, draw: []}, children: []}
      Renderer.render(tree, :android, MockNIF)
      {:set_root, [json]} = Enum.find(MockNIF.calls(), fn {f, _} -> f == :set_root end)
      assert :json.decode(json)["type"] == "canvas"
    end

    test "draw is serialized as a JSON array of op objects" do
      ops = [%{op: :line, x1: 0, y1: 0, x2: 10, y2: 10, color: :primary}]
      [op] = canvas_draw(ops)
      assert op["op"] == "line"
      assert {op["x1"], op["y1"], op["x2"], op["y2"]} == {0, 0, 10, 10}
    end

    test ":color tokens inside ops resolve through the theme" do
      Mob.Theme.set(primary: :emerald_500)
      [op] = canvas_draw([%{op: :line, x1: 0, y1: 0, x2: 1, y2: 1, color: :primary}])
      # emerald_500 → 0xFF10B981
      assert op["color"] == 0xFF10B981
    end

    test ":color hex strings pass through unchanged" do
      [op] = canvas_draw([%{op: :line, x1: 0, y1: 0, x2: 1, y2: 1, color: "#abcdef"}])
      assert op["color"] == "#abcdef"
    end

    test "raw palette atom resolves to ARGB integer" do
      [op] = canvas_draw([%{op: :circle, x: 10, y: 10, r: 5, color: :red_500}])
      assert op["color"] == 0xFFF44336
    end

    test "atom enums (cap, join, anchor, weight) become strings" do
      ops = [
        %{op: :line, x1: 0, y1: 0, x2: 1, y2: 1, color: :primary, cap: :round},
        %{op: :path, points: [[0, 0], [1, 1]], color: :primary, join: :bevel},
        %{op: :text, x: 0, y: 0, text: "hi", color: :primary, size: 12, anchor: :center}
      ]

      [line_op, path_op, text_op] = canvas_draw(ops)
      assert line_op["cap"] == "round"
      assert path_op["join"] == "bevel"
      assert text_op["anchor"] == "center"
    end

    test "numeric and boolean op fields pass through untouched" do
      [op] =
        canvas_draw([
          %{op: :rect, x: 1, y: 2, w: 3, h: 4, color: :primary, fill: true, radius: 8}
        ])

      assert op["fill"] == true
      assert op["radius"] == 8
      assert op["w"] == 3
    end

    test "path points serialize as an array of [x, y] arrays" do
      ops = [%{op: :path, points: [[0, 0], [10, 20], [30, 40]], color: :primary}]
      [op] = canvas_draw(ops)
      assert op["points"] == [[0, 0], [10, 20], [30, 40]]
    end

    test "Mob.Canvas helper output round-trips through the renderer" do
      Mob.Theme.set(primary: :emerald_500)
      ops = [Mob.Canvas.line(0, 0, 100, 100, color: :primary, width: 4, cap: :round)]
      [op] = canvas_draw(ops)
      assert op["op"] == "line"
      assert op["color"] == 0xFF10B981
      assert op["width"] == 4
      assert op["cap"] == "round"
    end
  end

  describe "theme glass flag" do
    setup do
      on_exit(fn -> Mob.Theme.set(%Mob.Theme{}) end)
      :ok
    end

    defp box_with_background do
      %{
        type: :box,
        props: %{background: :surface},
        children: [%{type: :text, props: %{text: "card"}, children: []}]
      }
    end

    defp set_root_json do
      MockNIF.calls()
      |> Enum.find_value(fn
        {:set_root, [json]} -> :json.decode(json)
        _ -> nil
      end)
    end

    test "Box with a background gets glass: true when theme.glass is on" do
      Mob.Theme.set(glass: true)
      Renderer.render(box_with_background(), :ios, MockNIF)

      tree = set_root_json()
      assert tree["type"] == "box"
      assert tree["props"]["glass"] == true
    end

    test "Box with no background does NOT get glass: true (nothing to swap)" do
      Mob.Theme.set(glass: true)

      Renderer.render(
        %{type: :box, props: %{}, children: []},
        :ios,
        MockNIF
      )

      tree = set_root_json()
      refute Map.has_key?(tree["props"], "glass")
    end

    test "non-box surface-style nodes are NOT marked (text, scroll, column)" do
      Mob.Theme.set(glass: true)

      Renderer.render(
        %{
          type: :column,
          props: %{background: :surface},
          children: [%{type: :text, props: %{text: "x", background: :surface}, children: []}]
        },
        :ios,
        MockNIF
      )

      tree = set_root_json()
      refute Map.has_key?(tree["props"], "glass")
      refute Map.has_key?(hd(tree["children"])["props"], "glass")
    end

    test "default theme (glass: false) emits no glass prop" do
      Mob.Theme.set(%Mob.Theme{})
      Renderer.render(box_with_background(), :ios, MockNIF)

      tree = set_root_json()
      refute Map.has_key?(tree["props"], "glass")
    end

    test "a glass: true theme triggers the flag at the boundary" do
      # (MobThemes.ObsidianGlass — now in the mob_themes style package — is
      # the shipped example of a glass theme; the renderer contract is the
      # flag itself.)
      Mob.Theme.set(%Mob.Theme{glass: true})
      Renderer.render(box_with_background(), :ios, MockNIF)

      tree = set_root_json()
      assert tree["props"]["glass"] == true
    end
  end

  describe "font token resolution" do
    setup do
      on_exit(fn -> Mob.Theme.set(%Mob.Theme{}) end)
      :ok
    end

    test "font atom resolves to the platform-specific name" do
      Mob.Theme.set(fonts: %{heading: %{ios: "Inter-Bold", android: "inter_bold"}})

      tree = %{type: :text, props: %{text: "hi", font: :heading}, children: []}

      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "Inter-Bold"

      MockNIF.reset()
      Renderer.render(tree, :android, MockNIF)
      assert set_root_json()["props"]["font"] == "inter_bold"
    end

    test "a bare string font value is used as-is on both platforms" do
      Mob.Theme.set(fonts: %{mono: "Courier"})
      tree = %{type: :text, props: %{text: "hi", font: :mono}, children: []}

      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "Courier"
    end

    test "unknown font atom is left as-is (serialised as string)" do
      tree = %{type: :text, props: %{text: "hi", font: :not_a_real_font}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "not_a_real_font"
    end

    test "a node with an explicit font: prop is untouched even with a default set" do
      Mob.Theme.set(
        fonts: %{
          default: %{ios: "Inter-Regular", android: "inter_regular"},
          heading: %{ios: "Inter-Bold", android: "inter_bold"}
        }
      )

      tree = %{type: :text, props: %{text: "hi", font: :heading}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "Inter-Bold"
    end

    test "a node with no font: prop gets the theme's :default font injected" do
      Mob.Theme.set(fonts: %{default: %{ios: "Inter-Regular", android: "inter_regular"}})

      tree = %{type: :text, props: %{text: "hi"}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "Inter-Regular"
    end

    test "default font injection is not restricted to :text — any node type gets it" do
      Mob.Theme.set(fonts: %{default: %{ios: "Inter-Regular", android: "inter_regular"}})

      tree = %{type: :button, props: %{text: "Save", on_tap: self()}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      assert set_root_json()["props"]["font"] == "Inter-Regular"
    end

    test "no :default font token configured: nothing is injected (zero-config no-op)" do
      Mob.Theme.set(%Mob.Theme{})

      tree = %{type: :text, props: %{text: "hi"}, children: []}
      Renderer.render(tree, :ios, MockNIF)
      refute Map.has_key?(set_root_json()["props"], "font")
    end
  end

  describe "sheet serialization" do
    setup do
      on_exit(fn -> Application.delete_env(:mob, :theme) end)
      :ok
    end

    # Builds the raw node map directly rather than going through Mob.UI.sheet/2
    # — Renderer serialization is tested independently of Mob.UI's validation
    # layer (which has its own test coverage in test/mob/ui_test.exs), so a
    # deliberately-incomplete prop set here (e.g. one indicator prop without
    # the other three) isn't rejected before reaching the code under test.
    defp sheet_tree(props, children \\ [%{type: :text, props: %{text: "hi"}, children: []}]) do
      %{type: :sheet, props: props, children: children}
    end

    test "type serializes as the string \"sheet\"" do
      Renderer.render(sheet_tree(%{}), :android, MockNIF)
      assert set_root_json()["type"] == "sheet"
    end

    test "children serialize recursively like normal children" do
      children = [
        %{type: :text, props: %{text: "a"}, children: []},
        %{type: :text, props: %{text: "b"}, children: []}
      ]

      Renderer.render(sheet_tree(%{}, children), :android, MockNIF)
      decoded_children = set_root_json()["children"]

      assert length(decoded_children) == 2
      assert Enum.at(decoded_children, 0)["props"]["text"] == "a"
      assert Enum.at(decoded_children, 1)["props"]["text"] == "b"
    end

    test "detents serialize as a list of strings" do
      Renderer.render(sheet_tree(%{detents: [:medium]}), :android, MockNIF)
      assert set_root_json()["props"]["detents"] == ["medium"]
    end

    test "on_dismiss registers through the tap registry and serializes as an integer handle" do
      tag = {self(), :dismissed}
      Renderer.render(sheet_tree(%{on_dismiss: tag}), :android, MockNIF)

      assert is_integer(set_root_json()["props"]["on_dismiss"])
      assert Enum.any?(MockNIF.calls(), fn {f, args} -> f == :register_tap and args == [tag] end)
    end

    test "scrim is a color-token prop — resolves through the theme like :background" do
      Mob.Theme.set(muted: :black)
      Renderer.render(sheet_tree(%{scrim: :muted}), :android, MockNIF)
      assert set_root_json()["props"]["scrim"] == 0xFF000000
    end

    test "scrim passes through a raw ARGB integer unresolved" do
      Renderer.render(sheet_tree(%{scrim: 0x33000000}), :android, MockNIF)
      assert set_root_json()["props"]["scrim"] == 0x33000000
    end

    test "drag_indicator_color is a color-token prop" do
      Mob.Theme.set(muted: :gray_500)
      Renderer.render(sheet_tree(%{drag_indicator_color: :muted}), :android, MockNIF)
      resolved = set_root_json()["props"]["drag_indicator_color"]
      assert is_integer(resolved)
    end

    test "an unresolvable scrim color token logs a warning and passes through unchanged" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Renderer.render(sheet_tree(%{scrim: :not_a_real_token}), :android, MockNIF)
        end)

      assert log =~ "not_a_real_token"
      assert set_root_json()["props"]["scrim"] == "not_a_real_token"
    end

    test "corner_radius resolves through radius tokens" do
      Mob.Theme.set(radius_md: 20)
      Renderer.render(sheet_tree(%{corner_radius: :radius_md}), :android, MockNIF)
      assert set_root_json()["props"]["corner_radius"] == 20
    end

    test "corner_radius passes a raw number through unresolved" do
      Renderer.render(sheet_tree(%{corner_radius: 10}), :android, MockNIF)
      assert set_root_json()["props"]["corner_radius"] == 10
    end

    test "drag_indicator_width/height/rail_height pass through as plain numbers" do
      Renderer.render(
        sheet_tree(%{
          drag_indicator_color: :muted,
          drag_indicator_width: 36,
          drag_indicator_height: 5,
          drag_indicator_rail_height: 22
        }),
        :android,
        MockNIF
      )

      props = set_root_json()["props"]
      assert props["drag_indicator_width"] == 36
      assert props["drag_indicator_height"] == 5
      assert props["drag_indicator_rail_height"] == 22
    end

    test "ios override flattens on ios platform, stripped from serialised JSON" do
      Renderer.render(
        sheet_tree(%{corner_radius: 10, ios: %{corner_radius: 4}}),
        :ios,
        MockNIF
      )

      props = set_root_json()["props"]
      assert props["corner_radius"] == 4
      refute Map.has_key?(props, "ios")
      refute Map.has_key?(props, "android")
    end

    test "android override flattens on android platform, ios override ignored" do
      Renderer.render(
        sheet_tree(%{corner_radius: 10, ios: %{corner_radius: 4}, android: %{corner_radius: 28}}),
        :android,
        MockNIF
      )

      assert set_root_json()["props"]["corner_radius"] == 28
    end

    test "base value used when the active platform has no override" do
      Renderer.render(
        sheet_tree(%{corner_radius: 10, ios: %{corner_radius: 4}}),
        :android,
        MockNIF
      )

      assert set_root_json()["props"]["corner_radius"] == 10
    end
  end
end
