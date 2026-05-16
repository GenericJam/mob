defmodule Mob.UITest do
  use ExUnit.Case, async: true

  alias Mob.UI

  # ── text/1 ───────────────────────────────────────────────────────────────────

  describe "text/1 with keyword list" do
    test "type is :text" do
      assert UI.text(text: "hello").type == :text
    end

    test "props contains the text" do
      assert UI.text(text: "hello").props.text == "hello"
    end

    test "children is always empty — text is a leaf node" do
      assert UI.text(text: "hello").children == []
    end

    test "optional text_color is included when given" do
      assert UI.text(text: "hi", text_color: "#ff0000").props.text_color == "#ff0000"
    end

    test "optional text_size is included when given" do
      assert UI.text(text: "hi", text_size: 18).props.text_size == 18
    end

    test "unrecognized props are omitted" do
      props = UI.text(text: "hi", font_weight: :bold, opacity: 0.5).props
      refute Map.has_key?(props, :font_weight)
      refute Map.has_key?(props, :opacity)
    end

    test "props without text_color and text_size contains only :text" do
      assert UI.text(text: "hi").props == %{text: "hi"}
    end
  end

  describe "text/1 with map" do
    test "accepts a plain map" do
      assert UI.text(%{text: "hello"}).type == :text
    end

    test "produces identical output to keyword list form" do
      assert UI.text(text: "hello", text_size: 16) ==
               UI.text(%{text: "hello", text_size: 16})
    end
  end

  describe "text/1 node shape" do
    test "always has exactly the keys :type, :props, :children" do
      node = UI.text(text: "hi")
      assert Map.keys(node) |> Enum.sort() == [:children, :props, :type]
    end

    test "is renderer-compatible — matches %{type:, props:, children:}" do
      assert %{type: :text, props: %{}, children: []} = UI.text(text: "")
    end
  end

  # ── canvas/1 ─────────────────────────────────────────────────────────────────

  describe "canvas/1" do
    test "type is :canvas" do
      assert UI.canvas(width: 100, height: 100, draw: []).type == :canvas
    end

    test "children is always empty — canvas is a leaf node" do
      assert UI.canvas(width: 100, height: 100, draw: []).children == []
    end

    test "props carries width / height / draw verbatim" do
      ops = [%{op: :line, x1: 0, y1: 0, x2: 10, y2: 10, color: :primary}]
      props = UI.canvas(width: 240, height: 240, draw: ops).props
      assert props.width == 240
      assert props.height == 240
      assert props.draw == ops
    end

    test "unrecognized props are omitted" do
      props = UI.canvas(width: 100, height: 100, draw: [], background: "#000").props
      refute Map.has_key?(props, :background)
    end

    test "accepts a plain map and produces identical output to the keyword form" do
      kw = UI.canvas(width: 100, height: 100, draw: [])
      m = UI.canvas(%{width: 100, height: 100, draw: []})
      assert kw == m
    end

    test "accepts Mob.Canvas helper output as draw entries" do
      ops = [
        Mob.Canvas.line(0, 0, 10, 10, color: :primary),
        Mob.Canvas.circle(50, 50, 25, color: :primary)
      ]

      assert UI.canvas(width: 100, height: 100, draw: ops).props.draw == ops
    end
  end

  describe "gpu_view/1" do
    @shader """
    fragment half4 fragment_main(VertexOut in [[stage_in]],
                                 constant Uniforms& u [[buffer(0)]]) {
      return half4(in.uv, 0.0, 1.0);
    }
    """

    test "type is :gpu_view" do
      node = UI.gpu_view(id: :mandelbrot, width: 350, height: 350, shader: @shader, uniforms: [])
      assert node.type == :gpu_view
    end

    test "children is always empty — gpu_view is a leaf node" do
      node = UI.gpu_view(id: :mandelbrot, width: 350, height: 350, shader: @shader, uniforms: [])
      assert node.children == []
    end

    test "props carries id / width / height / shader / uniforms verbatim" do
      uniforms = [[1.0, 2.0], 3.0, 256]

      props =
        UI.gpu_view(
          id: :foo,
          width: 200,
          height: 150,
          shader: @shader,
          uniforms: uniforms
        ).props

      assert props.id == :foo
      assert props.width == 200
      assert props.height == 150
      assert props.shader == @shader
      assert props.uniforms == uniforms
    end

    test "accepts shader as the map escape-hatch form" do
      shader_map = %{ios: @shader}
      props = UI.gpu_view(id: :x, width: 100, height: 100, shader: shader_map, uniforms: []).props
      assert props.shader == shader_map
    end

    test "unrecognized props are omitted" do
      props =
        UI.gpu_view(
          id: :x,
          width: 100,
          height: 100,
          shader: @shader,
          uniforms: [],
          background: "#000"
        ).props

      refute Map.has_key?(props, :background)
    end

    test "accepts a plain map and produces identical output to the keyword form" do
      kw =
        UI.gpu_view(id: :x, width: 100, height: 100, shader: @shader, uniforms: [1.0])

      m =
        UI.gpu_view(%{id: :x, width: 100, height: 100, shader: @shader, uniforms: [1.0]})

      assert kw == m
    end

    test "shape is renderer-compatible — %{type:, props:, children:}" do
      node = UI.gpu_view(id: :x, width: 100, height: 100, shader: @shader, uniforms: [])
      assert Map.keys(node) |> Enum.sort() == [:children, :props, :type]
    end

    test "carries on_tap / on_drag / on_pinch when supplied" do
      tap = {self(), :tapped}
      drag = {self(), :dragged}
      pinch = {self(), :pinched}

      props =
        UI.gpu_view(
          id: :x,
          width: 100,
          height: 100,
          shader: @shader,
          uniforms: [],
          on_tap: tap,
          on_drag: drag,
          on_pinch: pinch
        ).props

      assert props.on_tap == tap
      assert props.on_drag == drag
      assert props.on_pinch == pinch
    end

    test "uniforms list preserves declaration order (no Map iteration surprises)" do
      # The whole point of accepting a list — order is pinned to position,
      # not to whatever the runtime decides. The shader-side `Uniforms`
      # struct can declare its members in the same order and read them
      # verbatim. A map form does not give this guarantee (verified
      # empirically against the iPhone Mandelbrot demo, where
      # `%{center: ..., zoom: ..., max_iter: ...}` iterated as
      # `[:zoom, :max_iter, :center]` on the device BEAM and produced
      # black output until we switched to a list).
      uniforms = [[1.0, 2.0], 3.0, 256, [4.0, 5.0, 6.0, 7.0]]

      props =
        UI.gpu_view(id: :x, width: 100, height: 100, shader: @shader, uniforms: uniforms).props

      assert props.uniforms == uniforms
    end
  end
end
