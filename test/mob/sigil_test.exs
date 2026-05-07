# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
# Rationale: ~MOB is a compile-time sigil (Mob.Sigil.sigil_MOB/2). The check's
# static analysis cannot see through sigil macro expansion and flags the tests
# as "not calling application code". The tests are valid — they exercise the
# sigil at compile time and the resulting nodes at runtime.
defmodule Mob.SigilTest do
  use ExUnit.Case, async: true

  import Mob.Sigil

  # ── self-closing: string attributes ─────────────────────────────────────────

  describe "self-closing with string attrs" do
    test "produces correct type atom" do
      node = ~MOB(<Text text="hello" />)
      assert node.type == :text
    end

    test "captures string attribute" do
      node = ~MOB(<Text text="hello" />)
      assert node.props.text == "hello"
    end

    test "children is empty list" do
      node = ~MOB(<Text text="hello" />)
      assert node.children == []
    end

    test "multiple string attributes" do
      node = ~MOB(<Text text="hi" font_weight="bold" />)
      assert node.props.text == "hi"
      assert node.props.font_weight == "bold"
    end

    test "empty string attribute" do
      node = ~MOB(<Text text="" />)
      assert node.props.text == ""
    end
  end

  # ── self-closing: expression attributes ─────────────────────────────────────

  describe "self-closing with expression attrs" do
    test "evaluates a variable in scope" do
      greeting = "world"
      node = ~MOB(<Text text={greeting} />)
      assert node.props.text == "world"
    end

    test "evaluates map access" do
      assigns = %{name: "Alice"}
      node = ~MOB(<Text text={assigns.name} />)
      assert node.props.text == "Alice"
    end

    test "evaluates atom expression" do
      node = ~MOB(<Text text_size={:xl} />)
      assert node.props.text_size == :xl
    end

    test "evaluates tuple expression for on_tap" do
      handler = {self(), :ok}
      node = ~MOB(<Button text="OK" on_tap={handler} />)
      assert elem(node.props.on_tap, 1) == :ok
    end

    test "mixed string and expression attrs" do
      color = :primary
      node = ~MOB(<Button text="Save" background={color} />)
      assert node.props.text == "Save"
      assert node.props.background == :primary
    end
  end

  # ── nesting ──────────────────────────────────────────────────────────────────

  describe "nested layout" do
    test "column with single text child" do
      node = ~MOB"""
      <Column padding={16}>
        <Text text="hello" />
      </Column>
      """

      assert node.type == :column
      assert node.props.padding == 16
      assert length(node.children) == 1
      assert hd(node.children).type == :text
      assert hd(node.children).props.text == "hello"
    end

    test "multiple children" do
      node = ~MOB"""
      <Column>
        <Text text="one" />
        <Text text="two" />
        <Text text="three" />
      </Column>
      """

      assert length(node.children) == 3
      assert Enum.map(node.children, & &1.props.text) == ["one", "two", "three"]
    end

    test "deeply nested structure" do
      node = ~MOB"""
      <Column>
        <Row>
          <Text text="left" />
          <Text text="right" />
        </Row>
      </Column>
      """

      assert node.type == :column
      [row] = node.children
      assert row.type == :row
      assert length(row.children) == 2
    end

    test "self-closing and container siblings" do
      node = ~MOB"""
      <Column>
        <Text text="label" />
        <Row>
          <Button text="A" />
          <Button text="B" />
        </Row>
      </Column>
      """

      assert length(node.children) == 2
      [text, row] = node.children
      assert text.type == :text
      assert row.type == :row
      assert length(row.children) == 2
    end
  end

  # ── expression children ──────────────────────────────────────────────────────

  describe "expression child slots {expr}" do
    test "injects a single node from an expression" do
      child = %{type: :text, props: %{text: "dynamic"}, children: []}

      node = ~MOB"""
      <Column>
        {child}
      </Column>
      """

      assert length(node.children) == 1
      assert hd(node.children).props.text == "dynamic"
    end

    test "injects a list of nodes from Enum.map" do
      items = ["a", "b", "c"]

      node = ~MOB"""
      <Column>
        {Enum.map(items, fn i -> %{type: :text, props: %{text: i}, children: []} end)}
      </Column>
      """

      assert length(node.children) == 3
      assert Enum.map(node.children, & &1.props.text) == ["a", "b", "c"]
    end

    test "expression child mixed with static child" do
      extra = %{type: :divider, props: %{}, children: []}

      node = ~MOB"""
      <Column>
        <Text text="header" />
        {extra}
      </Column>
      """

      assert length(node.children) == 2
      assert hd(node.children).type == :text
      assert List.last(node.children).type == :divider
    end
  end

  # ── tag type resolution ──────────────────────────────────────────────────────

  describe "tag to type atom" do
    test "PascalCase becomes snake_case atom" do
      node = ~MOB(<TabBar />)
      assert node.type == :tab_bar
    end

    test "LazyList becomes :lazy_list" do
      node = ~MOB(<LazyList />)
      assert node.type == :lazy_list
    end

    test "TextField becomes :text_field" do
      node = ~MOB(<TextField value="x" />)
      assert node.type == :text_field
    end
  end

  # ── parity with raw maps ─────────────────────────────────────────────────────

  describe "parity with Mob.UI" do
    test "sigil output equals Mob.UI.text/1 for static attrs" do
      assert ~MOB(<Text text="hello" />) == Mob.UI.text(text: "hello")
    end

    test "sigil output equals Mob.UI.text/1 for expression attr" do
      text = "hello"
      assert ~MOB(<Text text={text} />) == Mob.UI.text(text: "hello")
    end
  end

  # ── unknown tags pass through with warning ───────────────────────────────────

  describe "unknown tag pass-through" do
    test "unknown tag produces a node with the derived type atom" do
      # MapView is not in the whitelist — should warn but still compile
      node = Code.eval_string(~S[
        import Mob.Sigil
        ~MOB(<MapView zoom={10} />)
      ]) |> elem(0)
      assert node.type == :map_view
      assert node.props.zoom == 10
    end
  end

  # ── compile-time errors ───────────────────────────────────────────────────────

  describe "compile-time errors" do
    test "mismatched tags raises CompileError" do
      assert_raise CompileError, ~r/mismatched tags/i, fn ->
        Code.compile_string(~S[import Mob.Sigil; ~MOB"""
        <Column>
          <Text text="hi" />
        </Row>
        """])
      end
    end

    test "malformed template raises CompileError" do
      assert_raise CompileError, fn ->
        Code.compile_string(~S[import Mob.Sigil; ~MOB(not a tag)])
      end
    end

    test "unclosed tag raises CompileError" do
      assert_raise CompileError, fn ->
        Code.compile_string(~S[import Mob.Sigil; ~MOB"""
        <Column>
          <Text text="hi" />
        """])
      end
    end
  end
end
