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
end
