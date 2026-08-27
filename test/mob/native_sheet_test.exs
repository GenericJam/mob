# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeSheetTest do
  use ExUnit.Case, async: true

  @ios Path.expand("../../ios", __DIR__)

  test "SwiftUI sheet preserves built-ins and measures content detents" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    assert source =~ "MobSheetContentHeightKey"
    assert source =~ "builtInDetents.contains(\"medium\")"
    assert source =~ "builtInDetents.contains(\"large\")"
    assert source =~ ".height(limitedContentHeight)"
    assert source =~ ".onPreferenceChange(MobSheetContentHeightKey.self)"
    assert source =~ "ScrollView(.vertical)"
  end

  test "content detent reclamps against live sheet geometry" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    assert source =~ "GeometryReader { geometry in"
    assert source =~ "availableSheetHeight = max(1, height * 0.9)"
    assert source =~ "min(intrinsicContentHeight, maximumHeight)"
    assert source =~ "let intrinsicHeight = max(1, measuredHeight)"
    assert source =~ "intrinsicContentHeight = intrinsicHeight"
    refute source =~ "UIScreen.main.bounds.height * 0.9"
  end
end
