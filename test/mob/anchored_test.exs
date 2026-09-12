defmodule Mob.AnchoredTest do
  # The `:anchored` node type: children[0] is the anchor (in flow), children[1]
  # the panel (floated over the page). These tests pin the Elixir-visible
  # contract — the whitelist, the sigil, ScreenCase's renderability — not the
  # native placement, which only a device run can verify.
  use Mob.ScreenCase, async: true

  import Mob.Sigil

  test "anchored is a renderable type on iOS" do
    assert :anchored in renderable_types()
  end

  test "a two-child anchored node passes assert_renderable" do
    dismiss = {self(), :close}

    tree = ~MOB"""
    <Anchored side="bottom" align="start" side_offset={4} on_tap={dismiss}>
      <Button text="Open" />
      <Box background={:surface} corner_radius={:radius_md} padding={:space_sm}>
        <Text text="Panel" />
      </Box>
    </Anchored>
    """

    assert tree.type == :anchored
    assert tree.props.side == "bottom"
    assert [%{type: :button}, %{type: :box}] = tree.children
    assert_renderable(tree)
  end

  test "a closed anchored node (anchor only) is still renderable" do
    tree = ~MOB"""
    <Anchored>
      <Button text="Open" />
    </Anchored>
    """

    assert [%{type: :button}] = tree.children
    assert_renderable(tree)
  end
end
