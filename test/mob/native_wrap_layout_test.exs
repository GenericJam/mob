# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeWrapLayoutTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "iOS parses wrap and its spacing props at the native boundary" do
    header = File.read!(Path.join(@root, "ios/MobNode.h"))
    implementation = File.read!(Path.join(@root, "ios/MobNode.m"))
    nif = File.read!(Path.join(@root, "ios/mob_nif.m"))

    assert header =~ "MobNodeTypeWrap"
    assert header =~ "CGFloat wrapSpacing"
    assert header =~ "CGFloat wrapRunSpacing"
    assert implementation =~ "_wrapSpacing = 0.0"
    assert implementation =~ "_wrapRunSpacing = 0.0"
    assert nif =~ ~s|[type isEqualToString:@"wrap"]|
    assert nif =~ "node.nodeType = MobNodeTypeWrap"
    assert nif =~ "pv[MOB_PROP_spacing]"
    assert nif =~ "pv[MOB_PROP_run_spacing]"
  end

  test "SwiftUI wrap measures children and preserves stable identity" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~ "private struct MobFlowLayout: Layout"
    assert source =~ "subview.sizeThatFits(.unspecified)"
    assert source =~ "x + spacing + itemSize.width > availableWidth"
    assert source =~ "MobFlowFillWidthKey.self"
    assert source =~ "!item.node.fillWidthSet && item.node.fixedWidth <= 0"
    assert source =~ "@Environment(\\.layoutDirection) private var layoutDirection"
    assert source =~ "layoutDirection == .rightToLeft"
    assert source =~ "anchor: UnitPoint(x: 0, y: 0)"
    assert source =~ "ForEach(mobIdentifiedChildren(node.childNodes))"
    assert source =~ "case .wrap:"
    assert source =~ "MobWrap(node: node)"
  end
end
