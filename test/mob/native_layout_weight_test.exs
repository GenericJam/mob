# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeLayoutWeightTest do
  use ExUnit.Case, async: true

  @ios Path.expand("../../ios", __DIR__)

  test "iOS parses layout weight at the native boundary" do
    header = File.read!(Path.join(@ios, "MobNode.h"))
    implementation = File.read!(Path.join(@ios, "MobNode.m"))
    nif = File.read!(Path.join(@ios, "mob_nif.m"))

    assert header =~ "CGFloat layoutWeight"
    assert implementation =~ "_layoutWeight = 0.0"
    # The deserialiser resolves prop keys to slots in one pass rather than
    # probing each key, so the contract is "weight" being in the slot table
    # AND the node builder reading that slot.
    assert nif =~ ~s|@"weight"|
    assert nif =~ "pv[MOB_PROP_weight]"
    assert nif =~ "node.layoutWeight = [layoutWeight doubleValue]"
  end

  test "iOS expands weighted children on their parent's main axis" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    # `item.node` since MOB-127: children are keyed by author :id through
    # mobIdentifiedChildren rather than by position, so the ForEach element is
    # the identified wrapper. The property being pinned is unchanged — a column
    # passes .vertical, a row .horizontal.
    assert source =~ "MobNodeView(node: item.node, layoutWeightAxis: .vertical)"
    assert source =~ "layoutWeightAxis: .horizontal,"
    assert source =~ "prioritizeHorizontalText: prioritizesText"
    assert source =~ ".modifier(MobLayoutWeight(node: node, axis: layoutWeightAxis))"
    assert source =~ "frame(maxHeight: .infinity, alignment: .top)"
    assert source =~ "frame(maxWidth: .infinity, alignment: .leading)"
    assert source =~ ".mobBoxBackground(node: node)"
  end

  # MOB-569. The ratio arithmetic is exercised for real by
  # test/native/weighted_stack_test.swift; what it cannot see is the renderer
  # handing rows and columns to that layout. Without this wiring every weight
  # is an even split again, with that native test still green.
  test "iOS rows and columns with a weighted child use the weighted layouts" do
    source =
      @ios
      |> Path.join("MobRootView.swift")
      |> File.read!()
      |> Mob.Test.NativeSource.code_only()

    row = Mob.Test.NativeSource.region(source, "case .row:", "case .wrap:")
    assert row =~ "mobHasStackWeights(node.childNodes, axis: .horizontal)"

    assert row =~
             "AnyLayout(MobWeightedRowLayout(alignment: alignment, spacing: CGFloat(node.gap)))"

    assert row =~ "rowLayout {"

    assert row =~
             ".layoutValue(key: MobStackWeightKey.self, value: mobStackWeight(item.node, axis: .horizontal))"

    column = Mob.Test.NativeSource.region(source, "case .column:", "case .row:")
    assert column =~ "weighted: mobHasStackWeights(node.childNodes, axis: .vertical)"

    assert column =~
             ".layoutValue(key: MobStackWeightKey.self, value: mobStackWeight(item.node, axis: .vertical))"

    stack =
      @ios
      |> Path.join("MobWeightedStack.swift")
      |> File.read!()
      |> Mob.Test.NativeSource.code_only()
      |> Mob.Test.NativeSource.region("struct MobEitherStack<Content: View>: View {", "\n}\n")

    assert stack =~ "AnyLayout(MobWeightedColumnLayout(alignment: alignment, spacing: spacing))"
  end

  # MOB-569. With an empty label the stock Toggle keeps its label + spacer
  # layout, and the maxWidth frame made it greedy: in a Row it took half the
  # width and drew the switch mid-row.
  test "iOS toggle without a label hugs its switch" do
    toggle =
      @ios
      |> Path.join("MobRootView.swift")
      |> File.read!()
      |> Mob.Test.NativeSource.code_only()
      |> Mob.Test.NativeSource.region("private struct MobToggle: View {", "\n}\n")

    assert toggle =~ ".ifLet(label.isEmpty ? () : nil) { view, _ in view.labelsHidden() }"
    assert toggle =~ ".frame(maxWidth: label.isEmpty ? nil : .infinity, alignment: .leading)"
    refute toggle =~ ".frame(maxWidth: .infinity, alignment: .leading)"
  end
end
