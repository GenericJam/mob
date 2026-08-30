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
    assert nif =~ ~s|props[@"weight"]|
    assert nif =~ "node.layoutWeight = [layoutWeight doubleValue]"
  end

  test "iOS expands weighted children on their parent's main axis" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    assert source =~ "MobNodeView(node: child, layoutWeightAxis: .vertical)"
    assert source =~ "MobNodeView(node: child, layoutWeightAxis: .horizontal)"
    assert source =~ ".modifier(MobLayoutWeight(node: node, axis: layoutWeightAxis))"
    assert source =~ "frame(maxHeight: .infinity, alignment: .top)"
    assert source =~ "frame(maxWidth: .infinity, alignment: .leading)"
    assert source =~ ".mobBoxBackground(node: node)"
  end
end
