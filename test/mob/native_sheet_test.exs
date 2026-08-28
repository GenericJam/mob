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
    # Unmeasured content must fall back to a real system detent, never to a
    # computed sentinel — .height(1) flashed a hairline on every presentation.
    assert source =~ "guard let height = limitedContentHeight else { return [.medium] }"
    assert source =~ ".height(height)"
    assert source =~ ".onPreferenceChange(MobSheetContentHeightKey.self)"
    assert source =~ "ScrollView(.vertical)"
  end

  test "content detent reclamps against live sheet geometry" do
    source = File.read!(Path.join(@ios, "MobRootView.swift"))

    assert source =~ "GeometryReader { geometry in"

    # Pin the mechanism, not the arithmetic. Asserting the literal
    # `max(1, height * 0.9)` made naming the fraction a test failure even
    # though behaviour was identical — these assertions should break when the
    # re-clamp stops working, not when someone extracts a constant.
    assert source =~ "onChange(of: geometry.size.height, initial: true)"
    assert source =~ "availableSheetHeight = max(1, height * Self.sheetHeightCeilingFraction)"
    assert source =~ "static let sheetHeightCeilingFraction"
    assert source =~ ".environment(\\.mobAvailableSheetHeight, availableSheetHeight)"

    # The detent is total sheet height, so the content's own bottom safe-area
    # inset has to be part of it or the last rows sit under the home indicator.
    assert source =~ "metrics.height + metrics.bottomInset"
    assert source =~ "safeAreaInsets.bottom"
    assert source =~ "contentMetrics = measured"
    refute source =~ "UIScreen.main.bounds.height * 0.9"
  end
end
