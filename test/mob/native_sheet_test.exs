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

  # #115. These sheet behaviours were verified on the iOS simulator; the
  # assertions pin the mechanisms that produce them.
  test "an authored :id is the sheet's identity, applied outside MobSheetView" do
    sheet =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("case .sheet:", "case .anchored:")

    # `.id` inside MobSheetView's body would not reset its @State, so it has to
    # wrap the constructor. Any NSString id keys it, "" included, as on
    # Android; a nil id leaves the slot identity. ObjectIdentifier would change
    # on every render, because the node is rebuilt each time.
    assert sheet =~
             ~r/MobSheetView\(node: node\)\s*\.ifLet\(node\.nativeViewId\) \{ view, id in view\.id\(id\) \}/

    refute sheet =~ "ObjectIdentifier"
  end

  test "a dismiss while the anchor is gone is held until it appears again" do
    body =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("private struct MobSheetView: View {", "\n}\n")

    # SwiftUI runs a replaced sheet's onDismiss after the replacement is in
    # place. The callback reads a class instance captured in body, not this
    # view's @State, which is no longer installed by then. A torn-down view
    # never appears again, so its held dismiss is never delivered; a hidden
    # one (deselected TabView tab) delivers it when it comes back.
    anchor = region(body, "let lifetime = lifetime", "sheetContent")
    assert anchor =~ ".onDisappear { lifetime.active = false }"

    on_dismiss = region(body, ".sheet(isPresented: $isPresented, onDismiss: {", "sheetContent")

    assert index_of(on_dismiss, "guard lifetime.active else {") <
             index_of(on_dismiss, "sendDismissOnce()"),
           "an inactive lifetime must hold the dismiss, not deliver it"

    assert on_dismiss =~ "lifetime.pendingDismiss = true"

    appear = region(anchor, ".onAppear {", ".onDisappear")
    assert appear =~ "lifetime.active = true"

    assert index_of(appear, "if lifetime.pendingDismiss {") <
             index_of(appear, "sendDismissOnce()")

    dismiss = region(body, "private func sendDismissOnce() {", "\n    }")

    assert index_of(dismiss, "if dismissedByPark { return }") <
             index_of(dismiss, "node.onDismiss?()")

    # A park only flips dismissedByPark. Deactivating here would swallow the
    # user's dismiss after the sheet comes back.
    watcher = region(body, ".onChange(of: isActive)", "\n            }")
    refute watcher =~ "lifetime"
  end

  test "a sheet asks to be presented from its first onAppear, not at init" do
    body =
      Path.join(@ios, "MobRootView.swift")
      |> File.read!()
      |> code_only()
      |> region("private struct MobSheetView: View {", "\n}\n")

    # Presenting in the update that removes an open predecessor put the
    # replacement up at the system default height with no drag indicator.
    assert body =~ "@State private var isPresented = false"

    appear = region(body, ".onAppear {", ".onDisappear")
    assert appear =~ "guard !appeared else { return }"
    assert appear =~ "isPresented = true"
    # Mounted on a parked screen: the resume presents it.
    assert appear =~ "dismissedByPark = true"
  end
end
