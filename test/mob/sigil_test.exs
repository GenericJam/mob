defmodule Mob.SigilTest do
  use ExUnit.Case, async: true

  import Mob.Sigil

  # ~MOB is an uppercase sigil — use () or [] delimiters so quote chars
  # inside the template don't need escaping.

  # ── static string attributes ─────────────────────────────────────────────────

  describe "~MOB static string attrs" do
    test "produces a :text node" do
      assert (~MOB(<Text text="hello" />)).type == :text
    end

    test "captures the text attribute" do
      assert (~MOB(<Text text="hello" />)).props.text == "hello"
    end

    test "text is a leaf — children is empty" do
      assert (~MOB(<Text text="hello" />)).children == []
    end

    test "captures text_color attribute" do
      node = ~MOB(<Text text="hi" text_color="#ff0000" />)
      assert node.props.text_color == "#ff0000"
    end

    test "captures text_size attribute as string" do
      node = ~MOB(<Text text="hi" text_size="18" />)
      assert node.props.text_size == "18"
    end

    test "empty text string is valid" do
      assert (~MOB(<Text text="" />)).props.text == ""
    end
  end

  # ── expression attributes ─────────────────────────────────────────────────────

  describe "~MOB expression attrs {expr}" do
    test "evaluates a variable in scope" do
      greeting = "world"
      assert (~MOB(<Text text={greeting} />)).props.text == "world"
    end

    test "evaluates an arbitrary expression" do
      # Hoist to variable — () inside {expr} conflicts with ~MOB() delimiter
      upcased = String.upcase("hello")
      assert (~MOB(<Text text={upcased} />)).props.text == "HELLO"
    end

    test "evaluates map access" do
      assigns = %{name: "Alice"}
      assert (~MOB(<Text text={assigns.name} />)).props.text == "Alice"
    end

    test "expression and literal attrs can be mixed" do
      color = "#0000ff"
      node = ~MOB(<Text text="hi" text_color={color} />)
      assert node.props.text == "hi"
      assert node.props.text_color == "#0000ff"
    end
  end

  # ── parity with Mob.UI.text/1 ──────────────────────────────────────────────

  describe "sigil/component function parity" do
    test "sigil output equals Mob.UI.text/1 for static attrs" do
      assert ~MOB(<Text text="hello" />) == Mob.UI.text(text: "hello")
    end

    test "sigil output equals Mob.UI.text/1 when using expression" do
      text = "hello"
      assert ~MOB(<Text text={text} />) == Mob.UI.text(text: "hello")
    end

    test "sigil and function node are interchangeable in a list" do
      nodes = [~MOB(<Text text="a" />), Mob.UI.text(text: "b")]
      assert Enum.all?(nodes, &match?(%{type: :text, children: []}, &1))
    end
  end

  # ── compile-time errors ───────────────────────────────────────────────────────

  describe "compile-time errors" do
    test "unknown component raises CompileError" do
      assert_raise CompileError, ~r/unknown component.*Paragraph/i, fn ->
        Code.eval_string(~S[import Mob.Sigil; ~MOB(<Paragraph text="hi" />)])
      end
    end

    test "malformed template raises CompileError" do
      assert_raise CompileError, ~r/self-closing/i, fn ->
        Code.eval_string(~S[import Mob.Sigil; ~MOB(not a tag)])
      end
    end
  end
end
