defmodule Mob.CanvasTest do
  use ExUnit.Case, async: true

  # Op constructors return plain maps. Tests pin the wire shape: the op
  # atom, the required positional fields, the accepted modifier set, and
  # rejection of typos. Color/token *resolution* belongs to Mob.Renderer
  # (covered by Mob.RendererTest's canvas section) — these tests stay at
  # the spec boundary on purpose.

  alias Mob.Canvas

  describe "line/5" do
    test "returns an :op => :line map with all four coordinates" do
      assert Canvas.line(10, 20, 100, 200, color: :primary) == %{
               op: :line,
               x1: 10,
               y1: 20,
               x2: 100,
               y2: 200,
               color: :primary
             }
    end

    test "accepts width / cap / dash / opacity modifiers" do
      op = Canvas.line(0, 0, 10, 10, color: :primary, width: 4, cap: :round, opacity: 0.5)
      assert op.width == 4
      assert op.cap == :round
      assert op.opacity == 0.5
    end

    test "missing :color raises with the op name in the message" do
      assert_raise ArgumentError, ~r/Mob\.Canvas\.line.*:color/, fn ->
        Canvas.line(0, 0, 10, 10, [])
      end
    end

    test "ignores unrecognized options (typo guard)" do
      op = Canvas.line(0, 0, 10, 10, color: :primary, stroke: 4, capp: :round)
      refute Map.has_key?(op, :stroke)
      refute Map.has_key?(op, :capp)
    end
  end

  describe "circle/4" do
    test "returns an :op => :circle map with center + radius" do
      assert Canvas.circle(50, 50, 25, color: :primary) ==
               %{op: :circle, x: 50, y: 50, r: 25, color: :primary}
    end

    test "accepts fill / width / opacity modifiers" do
      op = Canvas.circle(0, 0, 10, color: :primary, fill: true, width: 2, opacity: 0.8)
      assert op.fill == true
      assert op.width == 2
      assert op.opacity == 0.8
    end

    test "missing :color raises" do
      assert_raise ArgumentError, fn -> Canvas.circle(0, 0, 10, []) end
    end
  end

  describe "ellipse/5" do
    test "returns rx and ry as separate fields" do
      op = Canvas.ellipse(100, 100, 60, 30, color: :primary)
      assert op.op == :ellipse
      assert op.rx == 60
      assert op.ry == 30
    end

    test "accepts fill / width / dash / opacity" do
      op = Canvas.ellipse(0, 0, 10, 5, color: :primary, fill: true, dash: [4, 2])
      assert op.fill == true
      assert op.dash == [4, 2]
    end
  end

  describe "arc/6" do
    test "returns start_deg + end_deg" do
      op = Canvas.arc(0, 0, 50, 0, 90, color: :primary)
      assert op.op == :arc
      assert op.start_deg == 0
      assert op.end_deg == 90
    end

    test "accepts cap / width / opacity" do
      op = Canvas.arc(0, 0, 50, 0, 180, color: :primary, cap: :round, width: 3)
      assert op.cap == :round
      assert op.width == 3
    end
  end

  describe "rect/5" do
    test "returns x/y/w/h" do
      op = Canvas.rect(10, 20, 100, 50, color: :primary)
      assert op.op == :rect
      assert {op.x, op.y, op.w, op.h} == {10, 20, 100, 50}
    end

    test "accepts radius for rounded corners" do
      op = Canvas.rect(0, 0, 100, 50, color: :primary, radius: 8)
      assert op.radius == 8
    end

    test "accepts fill / width / join / dash / opacity" do
      op =
        Canvas.rect(0, 0, 10, 10,
          color: :primary,
          fill: true,
          width: 2,
          join: :round,
          dash: [4, 4]
        )

      assert op.fill == true
      assert op.width == 2
      assert op.join == :round
    end
  end

  describe "path/2" do
    test "normalizes {x, y} tuples to [x, y] lists for JSON" do
      op = Canvas.path([{0, 0}, {100, 0}, {50, 80}], color: :primary)
      assert op.op == :path
      assert op.points == [[0, 0], [100, 0], [50, 80]]
    end

    test "accepts pre-normalized [x, y] lists too" do
      op = Canvas.path([[0, 0], [10, 10]], color: :primary)
      assert op.points == [[0, 0], [10, 10]]
    end

    test "accepts closed / fill / cap / join modifiers" do
      op =
        Canvas.path([{0, 0}, {10, 10}],
          color: :primary,
          closed: true,
          fill: true,
          cap: :round,
          join: :miter
        )

      assert op.closed == true
      assert op.fill == true
      assert op.cap == :round
      assert op.join == :miter
    end

    test "raises on a malformed point" do
      assert_raise ArgumentError, ~r/expected a \{x, y\}/, fn ->
        Canvas.path([{0, 0}, "nope"], color: :primary)
      end
    end
  end

  describe "text/4" do
    test "returns position, content, color, size" do
      op = Canvas.text(10, 20, "hello", color: :on_surface, size: 18)

      assert op == %{
               op: :text,
               x: 10,
               y: 20,
               text: "hello",
               color: :on_surface,
               size: 18
             }
    end

    test "accepts weight / family / anchor / opacity" do
      op =
        Canvas.text(0, 0, "hi",
          color: :primary,
          size: 14,
          weight: :bold,
          family: "Helvetica",
          anchor: :center,
          opacity: 0.9
        )

      assert op.weight == :bold
      assert op.family == "Helvetica"
      assert op.anchor == :center
      assert op.opacity == 0.9
    end

    test "missing :color or :size raises" do
      assert_raise ArgumentError, ~r/:color/, fn ->
        Canvas.text(0, 0, "hi", size: 12)
      end

      assert_raise ArgumentError, ~r/:size/, fn ->
        Canvas.text(0, 0, "hi", color: :primary)
      end
    end
  end

  describe "image/6" do
    test "returns rect + source" do
      op = Canvas.image(10, 20, 100, 100, "logo")

      assert op == %{
               op: :image,
               x: 10,
               y: 20,
               w: 100,
               h: 100,
               source: "logo"
             }
    end

    test "accepts opacity" do
      op = Canvas.image(0, 0, 10, 10, "logo", opacity: 0.5)
      assert op.opacity == 0.5
    end
  end

  describe "options as map (parity with keyword list)" do
    test "circle with map opts produces same output as keyword opts" do
      kw = Canvas.circle(0, 0, 10, color: :primary, fill: true, width: 2)
      m = Canvas.circle(0, 0, 10, %{color: :primary, fill: true, width: 2})
      assert kw == m
    end

    test "path with map opts produces same output as keyword opts" do
      kw = Canvas.path([{0, 0}, {10, 10}], color: :primary, closed: true)
      m = Canvas.path([{0, 0}, {10, 10}], %{color: :primary, closed: true})
      assert kw == m
    end
  end

  describe "raw map equivalence (the spec is the wire format)" do
    test "Canvas.line/5 equals the equivalent map literal" do
      via_helper = Canvas.line(0, 0, 100, 100, color: :primary, width: 4)

      via_literal = %{
        op: :line,
        x1: 0,
        y1: 0,
        x2: 100,
        y2: 100,
        color: :primary,
        width: 4
      }

      assert via_helper == via_literal
    end
  end

  describe "coordinate system contract (pinned, for the renderer)" do
    # These tests don't render anything — the actual viewport scaling
    # happens in the host app's MobBridge.kt / MobBridge.swift. The
    # tests pin the *contract* the renderer must honor, so that
    # contract is captured in code and a future renderer rewrite has
    # something concrete to test against.

    test "coordinates are canvas-local logical units, not pixels" do
      # A draw op at (width/2, height/2) must land in the center of
      # the canvas regardless of the canvas's actual rendered pixel
      # size. The wire format carries the logical numbers; the host
      # renderer applies (size.pixels / declared_logical_units) per
      # axis. See Mob.Canvas @moduledoc "Coordinate system" section.
      op = Canvas.circle(320, 240, 10, color: :primary, fill: true)
      assert op.x == 320
      assert op.y == 240
      # No density / scale information is encoded into the wire — the
      # renderer derives it from the actual composable size at draw
      # time.
      refute Map.has_key?(op, :density)
      refute Map.has_key?(op, :scale)
    end

    test "scalar sizes (stroke width, radius, text size) are logical units too" do
      # The renderer must scale these by (sx + sy) / 2 so they don't
      # squash when the viewport is non-square. The wire carries the
      # raw numbers; no per-axis hint.
      stroke = Canvas.line(0, 0, 100, 100, color: :primary, width: 4)
      assert stroke.width == 4
      refute Map.has_key?(stroke, :width_px)

      circ = Canvas.circle(50, 50, 12, color: :primary)
      assert circ.r == 12
    end
  end
end
