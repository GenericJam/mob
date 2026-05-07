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
end
