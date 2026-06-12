defmodule Mob.CompositeTest do
  use ExUnit.Case, async: false

  # ── Fixture kit ─────────────────────────────────────────────────────────────

  defmodule Kit do
    @moduledoc false

    # A card: title + wrapped children (proves children pass-through).
    def card(props, children, _ctx) do
      %{
        type: :column,
        props: %{padding: Map.get(props, :padding, 8)},
        children: [
          %{type: :text, props: %{text: Map.fetch!(props, :title)}, children: []}
          | children
        ]
      }
    end

    # A combobox: TextField + rows (proves auto-injected event targets reach
    # built-in event props untouched in shape).
    def combobox(props, _children, _ctx) do
      %{
        type: :column,
        props: %{},
        children: [
          %{
            type: :text_field,
            props: %{value: Map.get(props, :query, ""), on_change: props[:on_change]},
            children: []
          }
          | for opt <- Map.get(props, :options, []) do
              %{type: :button, props: %{text: opt, on_tap: props[:on_select]}, children: []}
            end
        ]
      }
    end

    # A composite BUILT FROM another composite (fixpoint).
    def fancy_card(props, children, _ctx) do
      %{
        type: :demo_card,
        props: Map.put(props, :title, "Fancy: " <> props[:title]),
        children: children
      }
    end

    # Endless self-recursion (depth guard).
    def forever(props, children, _ctx) do
      %{type: :forever, props: props, children: children}
    end

    def boom(_props, _children, _ctx), do: raise("kit bug")
  end

  setup do
    Mob.Composite.reset()
    on_exit(fn -> Mob.Composite.reset() end)
    :ok
  end

  test "an unregistered tree passes through untouched" do
    tree = %{
      type: :column,
      props: %{},
      children: [%{type: :text, props: %{text: "x"}, children: []}]
    }

    assert Mob.Composite.expand(tree, self()) == tree
  end

  test "a registered composite expands to its widget tree, children preserved" do
    :ok = Mob.Composite.register(:demo_card, {Kit, :card})

    tree = %{
      type: :demo_card,
      props: %{title: "Hello"},
      children: [%{type: :text, props: %{text: "inner"}, children: []}]
    }

    expanded = Mob.Composite.expand(tree, self())
    assert expanded.type == :column
    assert [%{props: %{text: "Hello"}}, %{props: %{text: "inner"}}] = expanded.children
  end

  test "composites nest to a fixpoint (a composite emitting a composite)" do
    :ok = Mob.Composite.register(:demo_card, {Kit, :card})
    :ok = Mob.Composite.register(:fancy_card, {Kit, :fancy_card})

    tree = %{type: :fancy_card, props: %{title: "T"}, children: []}
    expanded = Mob.Composite.expand(tree, self())
    assert expanded.type == :column
    assert [%{props: %{text: "Fancy: T"}}] = expanded.children
  end

  test "on_* props written as strings/atoms arrive as {screen_pid, tag}" do
    :ok = Mob.Composite.register(:demo_combobox, {Kit, :combobox})

    tree = %{
      type: :demo_combobox,
      props: %{query: "ap", options: ["apple"], on_change: "q_changed", on_select: :picked},
      children: []
    }

    me = self()
    expanded = Mob.Composite.expand(tree, me)
    [field, button] = expanded.children
    assert field.props.on_change == {me, :q_changed}
    assert button.props.on_tap == {me, :picked}
  end

  test "already-shaped {pid, tag} event props pass through untouched" do
    :ok = Mob.Composite.register(:demo_combobox, {Kit, :combobox})
    target = {self(), :explicit}

    tree = %{type: :demo_combobox, props: %{options: [], on_change: target}, children: []}
    expanded = Mob.Composite.expand(tree, self())
    [field] = expanded.children
    assert field.props.on_change == target
  end

  test "composites inside ordinary children expand too" do
    :ok = Mob.Composite.register(:demo_card, {Kit, :card})

    tree = %{
      type: :scroll,
      props: %{},
      children: [%{type: :demo_card, props: %{title: "deep"}, children: []}]
    }

    assert %{children: [%{type: :column}]} = Mob.Composite.expand(tree, self())
  end

  test "the depth guard stops circular composites and logs" do
    :ok = Mob.Composite.register(:forever, {Kit, :forever})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        expanded = Mob.Composite.expand(%{type: :forever, props: %{}, children: []}, self())
        assert expanded == %{type: :column, props: %{}, children: []}
      end)

    assert log =~ "depth guard"
  end

  test "a crashing expander logs and renders an empty node, not a screen crash" do
    :ok = Mob.Composite.register(:bad, {Kit, :boom})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        expanded = Mob.Composite.expand(%{type: :bad, props: %{}, children: []}, self())
        assert expanded.type == :column
      end)

    assert log =~ "crashed"
  end

  test "manifest-declared composites register at boot (Mob.Plugins.register_composites)" do
    Mob.Plugins.install(%{composites: [%{atom: :demo_card, expand: {Kit, :card}, plugin: :kit}]})
    assert :ok = Mob.Plugins.register_composites()
    assert Mob.Composite.expanders()[:demo_card] == {Kit, :card}
  end

  test "malformed manifest composite entries are skipped without raising" do
    Mob.Plugins.install(%{composites: [%{atom: "not_an_atom", expand: :nope}, :garbage]})
    assert :ok = Mob.Plugins.register_composites()
    assert Mob.Composite.expanders() == %{}
  end
end
