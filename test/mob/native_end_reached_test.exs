defmodule Mob.NativeEndReachedTest do
  @moduledoc """
  `on_end_reached` fires on arrival at the end, not on content replacement
  (MOB-141).

  MOB-127 keyed children on the author's `:id`. That made replacing a list's
  contents give every row a new identity, so the last row's `.onAppear` runs
  again even though nobody scrolled, and a search screen re-queried on each
  keystroke fired one pagination request per keystroke where before it fired
  none. Source-asserted because there is no host-side way to run SwiftUI.
  """
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest
  use ExUnit.Case, async: true

  @ios File.read!(Path.expand("../../ios/MobRootView.swift", __DIR__))

  test "the lazy list owns state, and it is not paid by every node" do
    # MobNodeView renders every node in the tree, so an Optional<Int> there is
    # storage multiplied by thousands for something one node type uses.
    code = code_only(@ios)
    assert code =~ "private struct MobLazyList: View {"
    assert code =~ "case .lazyList:\n                MobLazyList(node: node)"

    node_view = region(code, "struct MobNodeView: View {", "\n    var body: some View {")
    refute node_view =~ "@State", "per-node state belongs on the lazy list, not on every node"
  end

  test "the callback is latched on the child count" do
    body = region(code_only(@ios), "private struct MobLazyList: View {", "\n}\n")

    assert body =~ "@State private var firedForCount: Int?"

    # Both guards, in order: last row, then not-already-fired. Dropping either
    # one restores the bug, and dropping the second is the subtle one because
    # the code still reads as though it were latched.
    assert body =~ "guard item.index == children.count - 1 else { return }"
    assert body =~ "guard firedForCount != children.count else { return }"

    # The latch must be set before the callback, so a handler that synchronously
    # re-renders cannot re-enter and fire twice for the same count.
    set_at = index_of(body, "firedForCount = children.count")
    fire_at = index_of(body, "node.onTap?()")
    assert set_at < fire_at, "the latch must be set before the callback runs"
  end

  test "the raw unlatched fire is gone" do
    # The exact shape that shipped: an .onAppear that fires whenever the last
    # row appears, with nothing remembering that it already did.
    code = code_only(@ios)

    refute code =~ ~r/if item\.index == node\.childNodes\.count - 1 \{\s*node\.onTap\?\(\)/,
           "the unlatched last-row fire must not come back"
  end

  test "children are still keyed by identity, not position" do
    # The latch is not a licence to undo MOB-127; both properties hold together.
    body = region(code_only(@ios), "private struct MobLazyList: View {", "\n}\n")
    assert body =~ "ForEach(children)"
    assert body =~ "let children = mobIdentifiedChildren(node.childNodes)"
  end

  defp code_only(source) do
    source
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r{^\s*//.*$}, ""))
    |> Enum.join("\n")
  end

  defp region(source, from, to) do
    [_, rest] = String.split(source, from, parts: 2)
    [body | _] = String.split(rest, to, parts: 2)
    body
  end

  defp index_of(hay, needle) do
    case :binary.match(hay, needle) do
      {i, _} -> i
      :nomatch -> flunk("expected to find #{inspect(needle)}")
    end
  end
end
