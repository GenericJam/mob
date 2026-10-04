# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeSheetTest do
  use ExUnit.Case, async: true

  import Mob.Test.NativeSource

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

  test "a non-empty :id is the sheet's identity, and an empty one stays on the slot" do
    sheet =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("case .sheet:", "case .anchored:")

    # The constructor itself carries no `.id`. ifLet applies `.id` only after
    # a nil or empty nativeViewId has been dropped, so those sheets keep the
    # slot's identity. The value is the authored string: a rerender with the
    # same id does not change it, and a different id does. ObjectIdentifier
    # would change on every render, because the node is rebuilt each time.
    assert sheet =~ "MobSheetView(node: node)"
    refute sheet =~ "MobSheetView(node: node).id("
    refute sheet =~ "ObjectIdentifier"
    assert sheet =~ "nativeViewId.flatMap { $0.isEmpty ? nil : $0 }"
    assert sheet =~ "view.id(id)"
    assert index_of(sheet, "isEmpty") < index_of(sheet, "view.id(id)")
  end

  test "a disposed sheet does not deliver on_dismiss, and a swipe still does" do
    body =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("private struct MobSheetView: View {", "\n}\n")

    # Captured at body evaluation. Reading the flag back out of @State after
    # this identity is gone can observe the replacement, which starts active.
    anchor = region(body, "let lifetime = lifetime", "sheetContent")

    assert anchor =~ ".sheet(isPresented:"

    assert anchor =~ ".onDisappear { lifetime.active = false }",
           "the anchor that owns .sheet must deactivate on disappear"

    assert anchor =~ "if !lifetime.active { return }"

    assert index_of(anchor, "if !lifetime.active { return }") <
             index_of(anchor, "sendDismissOnce()"),
           "an inactive lifetime must return before the dismiss is delivered"

    refute anchor =~ "node.onDismiss"

    dismiss = region(body, "private func sendDismissOnce() {", "\n    }")

    assert index_of(dismiss, "if dismissedByPark { return }") <
             index_of(dismiss, "node.onDismiss?()")

    # A park only flips dismissedByPark. Deactivating here would swallow the
    # dismiss that the return is supposed to re-present past.
    watcher = region(body, ".onChange(of: isActive)", "\n            }")
    refute watcher =~ "lifetime"
    refute watcher =~ "active = false"
  end
end
