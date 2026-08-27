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

  # ── sheet/2 ──────────────────────────────────────────────────────────────────

  describe "sheet/2 constructor" do
    test "type is :sheet" do
      assert UI.sheet(UI.text(text: "hi")).type == :sheet
    end

    test "accepts a single child node, wrapped into a list" do
      assert UI.sheet(UI.text(text: "hi")).children == [UI.text(text: "hi")]
    end

    test "accepts a list of child nodes verbatim" do
      children = [UI.text(text: "a"), UI.text(text: "b")]
      assert UI.sheet(children).children == children
    end

    test "defaults :detents to [:medium, :large]" do
      assert UI.sheet(UI.text(text: "hi")).props.detents == [:medium, :large]
    end

    test "accepts a plain map and produces identical output to the keyword form" do
      kw = UI.sheet(UI.text(text: "hi"), detents: [:medium])
      m = UI.sheet(UI.text(text: "hi"), %{detents: [:medium]})
      assert kw == m
    end

    test "shape is renderer-compatible — %{type:, props:, children:}" do
      node = UI.sheet(UI.text(text: "hi"))
      assert Map.keys(node) |> Enum.sort() == [:children, :props, :type]
    end
  end

  describe "sheet/2 detents" do
    test "accepts [:medium]" do
      assert UI.sheet(UI.text(text: "hi"), detents: [:medium]).props.detents == [:medium]
    end

    test "accepts [:large]" do
      assert UI.sheet(UI.text(text: "hi"), detents: [:large]).props.detents == [:large]
    end

    test "accepts [:medium, :large] in either order" do
      assert UI.sheet(UI.text(text: "hi"), detents: [:large, :medium]).props.detents == [
               :large,
               :medium
             ]
    end

    test "rejects an empty list" do
      assert_raise ArgumentError, ~r/nonempty/, fn ->
        UI.sheet(UI.text(text: "hi"), detents: [])
      end
    end

    test "rejects duplicates" do
      assert_raise ArgumentError, ~r/duplicates/, fn ->
        UI.sheet(UI.text(text: "hi"), detents: [:medium, :medium])
      end
    end

    test "rejects a detent outside [:medium, :large]" do
      assert_raise ArgumentError, ~r/subset/, fn ->
        UI.sheet(UI.text(text: "hi"), detents: [:medium, :full])
      end
    end

    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/nonempty list/, fn ->
        UI.sheet(UI.text(text: "hi"), detents: :medium)
      end
    end
  end

  describe "sheet/2 on_dismiss" do
    test "accepts {pid, atom}" do
      tag = {self(), :dismissed}
      assert UI.sheet(UI.text(text: "hi"), on_dismiss: tag).props.on_dismiss == tag
    end

    test "omitted is fine — no on_dismiss key in props" do
      refute Map.has_key?(UI.sheet(UI.text(text: "hi")).props, :on_dismiss)
    end

    test "rejects a bare pid (no tag)" do
      assert_raise ArgumentError, ~r/on_dismiss/, fn ->
        UI.sheet(UI.text(text: "hi"), on_dismiss: self())
      end
    end

    test "rejects a non-pid first element" do
      assert_raise ArgumentError, ~r/on_dismiss/, fn ->
        UI.sheet(UI.text(text: "hi"), on_dismiss: {:not_a_pid, :dismissed})
      end
    end

    test "rejects a non-atom tag" do
      assert_raise ArgumentError, ~r/on_dismiss/, fn ->
        UI.sheet(UI.text(text: "hi"), on_dismiss: {self(), "dismissed"})
      end
    end
  end

  describe "sheet/2 style props" do
    test "accepts a theme-token atom for :background" do
      assert UI.sheet(UI.text(text: "hi"), background: :surface).props.background == :surface
    end

    test "accepts a raw ARGB integer for :background" do
      assert UI.sheet(UI.text(text: "hi"), background: 0x33000000).props.background == 0x33000000
    end

    test "0x00000000 and 0xFFFFFFFF are both valid (boundary check)" do
      assert UI.sheet(UI.text(text: "hi"), scrim: 0x00000000).props.scrim == 0
      assert UI.sheet(UI.text(text: "hi"), scrim: 0xFFFFFFFF).props.scrim == 0xFFFFFFFF
    end

    test "accepts a theme radius token atom or a non-negative number for :corner_radius" do
      assert UI.sheet(UI.text(text: "hi"), corner_radius: :radius_lg).props.corner_radius ==
               :radius_lg

      assert UI.sheet(UI.text(text: "hi"), corner_radius: 10).props.corner_radius == 10
      assert UI.sheet(UI.text(text: "hi"), corner_radius: 0).props.corner_radius == 0
    end

    test "unrecognized props pass through — sheet doesn't allowlist beyond validation" do
      # Unlike text/1 and canvas/1 (which Map.take an explicit allowlist),
      # sheet/2 only validates the KNOWN style keys and otherwise passes
      # opts through — :detents/:on_dismiss/:ios/:android live alongside
      # arbitrary future props without needing a matching Map.take update.
      props = UI.sheet(UI.text(text: "hi"), on_dismiss: {self(), :x}).props
      assert Map.has_key?(props, :on_dismiss)
    end

    for {label, value} <- [
          {"nil", nil},
          {"true", true},
          {"false", false},
          {"a string", "#ff0000"},
          {"a negative integer", -1},
          {"an integer above 0xFFFFFFFF", 0x100000000}
        ] do
      test "rejects #{label} as :background" do
        assert_raise ArgumentError, ~r/:background/, fn ->
          UI.sheet(UI.text(text: "hi"), background: unquote(Macro.escape(value)))
        end
      end

      test "rejects #{label} as :scrim" do
        assert_raise ArgumentError, ~r/:scrim/, fn ->
          UI.sheet(UI.text(text: "hi"), scrim: unquote(Macro.escape(value)))
        end
      end

      test "rejects #{label} as :drag_indicator_color (via the full-indicator form)" do
        assert_raise ArgumentError, ~r/:drag_indicator_color/, fn ->
          UI.sheet(UI.text(text: "hi"),
            drag_indicator_color: unquote(Macro.escape(value)),
            drag_indicator_width: 36,
            drag_indicator_height: 5,
            drag_indicator_rail_height: 22
          )
        end
      end
    end

    test "rejects nil/true/false as :corner_radius" do
      for bad <- [nil, true, false] do
        assert_raise ArgumentError, ~r/:corner_radius/, fn ->
          UI.sheet(UI.text(text: "hi"), corner_radius: bad)
        end
      end
    end

    test "rejects a negative :corner_radius" do
      assert_raise ArgumentError, ~r/:corner_radius/, fn ->
        UI.sheet(UI.text(text: "hi"), corner_radius: -1)
      end
    end
  end

  describe "sheet/2 drag indicator geometry" do
    @full_indicator [
      drag_indicator_color: :muted,
      drag_indicator_width: 36,
      drag_indicator_height: 5,
      drag_indicator_rail_height: 22
    ]

    test "accepts all four together" do
      props = UI.sheet(UI.text(text: "hi"), @full_indicator).props
      assert props.drag_indicator_width == 36
      assert props.drag_indicator_height == 5
      assert props.drag_indicator_rail_height == 22
      assert props.drag_indicator_color == :muted
    end

    test "omitting all four is fine — platform default indicator" do
      props = UI.sheet(UI.text(text: "hi")).props
      refute Map.has_key?(props, :drag_indicator_color)
      refute Map.has_key?(props, :drag_indicator_width)
    end

    for missing <- [
          :drag_indicator_color,
          :drag_indicator_width,
          :drag_indicator_height,
          :drag_indicator_rail_height
        ] do
      test "rejects supplying only 3 of 4 (missing #{missing})" do
        partial = Keyword.delete(@full_indicator, unquote(missing))

        assert_raise ArgumentError, ~r/requires all of/, fn ->
          UI.sheet(UI.text(text: "hi"), partial)
        end
      end
    end

    test "rejects width == 0" do
      opts = Keyword.put(@full_indicator, :drag_indicator_width, 0)

      assert_raise ArgumentError, ~r/:drag_indicator_width must be positive/, fn ->
        UI.sheet(UI.text(text: "hi"), opts)
      end
    end

    test "rejects a negative height" do
      opts = Keyword.put(@full_indicator, :drag_indicator_height, -1)

      assert_raise ArgumentError, ~r/:drag_indicator_height/, fn ->
        UI.sheet(UI.text(text: "hi"), opts)
      end
    end

    test "rejects rail_height < height" do
      opts =
        @full_indicator
        |> Keyword.put(:drag_indicator_height, 20)
        |> Keyword.put(:drag_indicator_rail_height, 5)

      assert_raise ArgumentError, ~r/rail_height.*must be >=/, fn ->
        UI.sheet(UI.text(text: "hi"), opts)
      end
    end

    test "accepts rail_height == height (boundary)" do
      opts =
        @full_indicator
        |> Keyword.put(:drag_indicator_height, 10)
        |> Keyword.put(:drag_indicator_rail_height, 10)

      assert UI.sheet(UI.text(text: "hi"), opts).props.drag_indicator_rail_height == 10
    end

    test "a non-numeric width doesn't silently pass the positivity check" do
      # Regression guard: Elixir's structural `>` never raises across types
      # (an atom compares greater than any number), so if type-checking
      # didn't run before the width > 0 check, a garbage atom would slip
      # through as "positive." Confirms the type error fires first.
      opts = Keyword.put(@full_indicator, :drag_indicator_width, :not_a_number)

      assert_raise ArgumentError, ~r/:drag_indicator_width must be a non-negative number/, fn ->
        UI.sheet(UI.text(text: "hi"), opts)
      end
    end
  end

  describe "sheet/2 platform overrides" do
    test "accepts :ios and :android maps with supported style keys" do
      props =
        UI.sheet(UI.text(text: "hi"),
          corner_radius: 10,
          ios: %{corner_radius: 10},
          android: %{corner_radius: 28}
        ).props

      assert props.ios == %{corner_radius: 10}
      assert props.android == %{corner_radius: 28}
    end

    test "rejects :detents inside an :ios override" do
      assert_raise ArgumentError, ~r/unsupported keys/, fn ->
        UI.sheet(UI.text(text: "hi"), ios: %{detents: [:medium]})
      end
    end

    test "rejects :on_dismiss inside an :android override" do
      assert_raise ArgumentError, ~r/unsupported keys/, fn ->
        UI.sheet(UI.text(text: "hi"), android: %{on_dismiss: {self(), :x}})
      end
    end

    test "rejects an invalid color value inside an override map" do
      assert_raise ArgumentError, ~r/:background/, fn ->
        UI.sheet(UI.text(text: "hi"), ios: %{background: nil})
      end
    end

    test "rejects a non-map :ios value" do
      assert_raise ArgumentError, ~r/:ios must be a map/, fn ->
        UI.sheet(UI.text(text: "hi"), ios: "not a map")
      end
    end
  end
end
