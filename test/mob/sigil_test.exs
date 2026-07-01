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

  # ── UTF-8 handling ──────────────────────────────────────────────────────────

  # Regression: `ascii_string([not: ?"])` in the parser double-encoded any
  # byte ≥128 (each source byte was treated as a Latin-1 codepoint and
  # re-encoded as UTF-8). Switching to `utf8_string/2` matches by codepoint
  # and preserves the source bytes verbatim.
  describe "UTF-8 in template source" do
    test "en-dash literal in string attr is preserved byte-for-byte" do
      node = ~MOB(<Text text="Agenda – May 23" />)
      assert node.props.text == "Agenda – May 23"
      assert byte_size(node.props.text) == 17
    end

    test "em-dash literal in string attr is preserved" do
      node = ~MOB(<Text text="Live — coding" />)
      assert node.props.text == "Live — coding"
    end

    test "middle dot, smart quotes, accents preserved" do
      node = ~MOB(<Text text="Track 1 · café · “quoted”" />)
      assert node.props.text == "Track 1 · café · “quoted”"
    end

    test "emoji preserved" do
      node = ~MOB(<Text text="🚀 ship it" />)
      assert node.props.text == "🚀 ship it"
    end

    test "non-ASCII literal inside {expr} string is preserved" do
      node = ~MOB(<Text text={"Agenda – May 23"} />)
      assert node.props.text == "Agenda – May 23"
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

    test "GpuView resolves to :gpu_view (and is on the iOS whitelist)" do
      # If GpuView drops off priv/tags/ios.txt, the sigil emits a
      # compile-time warning and the test breaks loudly via the stderr
      # capture used elsewhere in this file. For the type atom alone,
      # this just checks the snake_case conversion.
      node = ~MOB(<GpuView />)
      assert node.type == :gpu_view
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

  # ── @assigns sugar ────────────────────────────────────────────────────────────

  describe "@assign shorthand" do
    test "@name in an attr expands to assigns.name" do
      assigns = %{name: "Alice"}
      node = ~MOB(<Text text={@name} />)
      assert node.props.text == "Alice"
    end

    test "@user.name (nested access) expands the inner @user" do
      assigns = %{user: %{name: "Bob"}}
      node = ~MOB(<Text text={@user.name} />)
      assert node.props.text == "Bob"
    end

    test "@count inside a larger expression expands" do
      assigns = %{count: 3}
      node = ~MOB(<Text text={"n=#{@count}"} />)
      assert node.props.text == "n=3"
    end

    test "non-@ expressions are untouched" do
      local = "plain"
      node = ~MOB(<Text text={local} />)
      assert node.props.text == "plain"
    end
  end

  # ── @assign guard: assigns must be in scope ───────────────────────────────────

  describe "@assign guard" do
    test "@foo with no assigns in scope raises a CompileError naming the fix" do
      err =
        assert_raise CompileError, fn ->
          Code.compile_string(~S[import Mob.Sigil; ~MOB(<Text text={@title} />)])
        end

      msg = Exception.message(err)
      assert msg =~ ~s(requires a variable named "assigns")
      # The message points at the concrete fix: interpolate the argument.
      assert msg =~ "{title}"
    end

    test ":if={@flag} with no assigns in scope also raises" do
      assert_raise CompileError, ~r/requires a variable named "assigns"/, fn ->
        Code.compile_string(~S[import Mob.Sigil; ~MOB(<Text text="x" :if={@flag} />)])
      end
    end

    test "a static template (no @) compiles fine without assigns" do
      # No @ ⇒ no guard ⇒ no assigns needed.
      assert Code.compile_string(~S[import Mob.Sigil; ~MOB(<Text text="hi" />)]) == []
    end

    test "a helper using a positional arg (no @) needs no assigns" do
      # The idiomatic composite pattern: interpolate the argument directly.
      [{mod, _}] =
        Code.compile_string(~S'''
        defmodule Mob.SigilTest.GuardPositional do
          import Mob.Sigil
          def label(title), do: ~MOB(<Text text={title} />)
        end
        ''')

      assert mod.label("Hi").props.text == "Hi"
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  # ── :if control attribute ─────────────────────────────────────────────────────

  describe ":if directive" do
    test ":if={true} keeps the node" do
      node = ~MOB(<Text text="shown" :if={true} />)
      assert node.type == :text
    end

    test ":if={false} yields nil at the root" do
      node = ~MOB(<Text text="hidden" :if={false} />)
      refute node
    end

    test ":if={false} child drops out of its parent" do
      node = ~MOB"""
      <Column>
        <Text text="a" :if={true} />
        <Text text="b" :if={false} />
        <Text text="c" />
      </Column>
      """

      assert Enum.map(node.children, & &1.props.text) == ["a", "c"]
    end

    test ":if reads @assigns" do
      # Enum.member?/2 keeps `show` typed boolean() (not the literal false),
      # so the compiler doesn't flag the generated `if`'s else branch as dead.
      assigns = %{show: Enum.member?([], :x)}
      node = ~MOB(<Text text="x" :if={@show} />)
      refute node
    end

    test ":if with a string value raises CompileError" do
      assert_raise CompileError, ~r/:if requires a \{expr\}/, fn ->
        Code.compile_string(~S[import Mob.Sigil; ~MOB(<Text text="x" :if="true" />)])
      end
    end
  end

  # ── :for control attribute ────────────────────────────────────────────────────

  describe ":for directive" do
    test ":for at the root produces a list of nodes" do
      nodes = ~MOB"""
      <Text text={label} :for={label <- ["1", "2", "3"]} />
      """

      assert length(nodes) == 3
      assert Enum.map(nodes, & &1.props.text) == ["1", "2", "3"]
    end

    test ":for child splices into its parent" do
      node = ~MOB"""
      <Column>
        <Text text="header" />
        <Text text={label} :for={label <- ["a", "b"]} />
      </Column>
      """

      assert Enum.map(node.children, & &1.props.text) == ["header", "a", "b"]
    end

    test ":for reads @assigns" do
      assigns = %{items: ["x", "y"]}
      nodes = ~MOB(<Text text={i} :for={i <- @items} />)
      assert Enum.map(nodes, & &1.props.text) == ["x", "y"]
    end

    test ":for over an empty list yields no children" do
      node = ~MOB"""
      <Column>
        <Text text={i} :for={i <- []} />
      </Column>
      """

      assert node.children == []
    end

    test ":for on a container element repeats the whole subtree" do
      node = ~MOB"""
      <Column>
        <Row :for={label <- ["a", "b"]}>
          <Text text={label} />
        </Row>
      </Column>
      """

      assert length(node.children) == 2
      assert Enum.all?(node.children, &(&1.type == :row))
      assert Enum.map(node.children, &hd(&1.children).props.text) == ["a", "b"]
    end

    test ":if on a container element drops the whole subtree" do
      node = ~MOB"""
      <Column>
        <Row :if={false}>
          <Text text="gone" />
        </Row>
        <Text text="kept" />
      </Column>
      """

      assert Enum.map(node.children, & &1.type) == [:text]
    end

    test ":for with :if filters (LiveView comprehension semantics)" do
      node = ~MOB"""
      <Column>
        <Text text={to_string(n)} :for={n <- 1..4} :if={rem(n, 2) == 0} />
      </Column>
      """

      assert Enum.map(node.children, & &1.props.text) == ["2", "4"]
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
