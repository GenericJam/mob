# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeColumnRowLayoutTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @root Path.expand("../..", __DIR__)

  # MOB-181. Column previously used `.frame(maxWidth: .infinity, maxHeight: ...)`
  # unconditionally, so an author-supplied `fixed_width` / `fixed_height` on a
  # column was silently overridden by the fill frame. The fix pins the fixed
  # dims via an inner `.frame(width:height:)` and suppresses the outer max on
  # whichever axis is already pinned. Anchored to the Column case's
  # `MobEitherStack(...)` opener so a refactor that moves this block out of
  # the Column case fails the test rather than passing on the same tokens
  # somewhere else in the file.
  test "iOS column applies fixed_width and fixed_height" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~
             "                MobEitherStack(\n" <>
               "                    lazy: lazyContainer,\n" <>
               "                    alignment: .leading,\n" <>
               "                    spacing: CGFloat(node.gap),\n" <>
               "                    weighted: mobHasStackWeights(node.childNodes, axis: .vertical)\n" <>
               "                ) {"

    stack = File.read!(Path.join(@root, "ios/MobWeightedStack.swift"))
    assert stack =~ "LazyVStack(alignment: alignment, spacing: spacing) { content }"
    assert stack =~ "AnyLayout(VStackLayout(alignment: alignment, spacing: spacing))"

    assert source =~
             "                .frame(\n" <>
               "                    width: node.fixedWidth > 0 ? CGFloat(node.fixedWidth) : nil,\n" <>
               "                    height: node.fixedHeight > 0 ? CGFloat(node.fixedHeight) : nil,\n" <>
               "                    alignment: .topLeading\n" <>
               "                )\n" <>
               "                .frame(\n" <>
               "                    maxWidth: ((node.fillWidth || screenRoot) && node.fixedWidth <= 0) ? .infinity : nil,\n" <>
               "                    maxHeight: (node.fillHeight && node.fixedHeight <= 0) ? .infinity : nil,\n" <>
               "                    alignment: .topLeading\n" <>
               "                )"
  end

  # MOB-564. A Column took maxWidth: .infinity whenever it had no `width`, so
  # it filled its parent even with `fill_width: false`, while Compose's Column
  # wraps its content. It now fills only for `fill_width: true` or when it is
  # the node a screen slot hosts, which Android composes with fillMaxSize.
  test "iOS column hugs its content unless fill_width or screen root" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift")) |> NativeSource.code_only()

    refute source =~ "maxWidth: node.fixedWidth > 0 ? nil : .infinity,"

    assert source =~
             "maxWidth: ((node.fillWidth || screenRoot) && node.fixedWidth <= 0) ? .infinity : nil,"

    assert source =~ "MobNodeView(node: root, screenRoot: true)"
    assert source =~ "&& lhs.screenRoot == rhs.screenRoot"
    assert [_, _] = String.split(source, "screenRoot: true")
  end

  # MOB-181. Row previously only honoured `fill_width` and ignored `fixed_width`
  # / `fixed_height` entirely. The fix adds the same inner `.frame(width:height:)`
  # gate as the column case and suppresses the fill_width outer frame when the
  # width axis is already pinned. Anchored to the Row-case HStack opener above
  # it.
  test "iOS row applies fixed_width and fixed_height" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~
             "                    : AnyLayout(HStackLayout(alignment: alignment, spacing: CGFloat(node.gap)))\n" <>
               "                rowLayout {"

    assert source =~
             "                .frame(\n" <>
               "                    width: node.fixedWidth > 0 ? CGFloat(node.fixedWidth) : nil,\n" <>
               "                    height: node.fixedHeight > 0 ? CGFloat(node.fixedHeight) : nil,\n" <>
               "                    alignment: .leading\n" <>
               "                )\n" <>
               "                .ifLet((node.fillWidth && node.fixedWidth <= 0) ? () : nil) { view, _ in\n" <>
               "                    view.frame(maxWidth: .infinity, alignment: .leading)\n" <>
               "                }"
  end

  test "iOS parses stack gap at the native boundary" do
    header = File.read!(Path.join(@root, "ios/MobNode.h"))
    implementation = File.read!(Path.join(@root, "ios/MobNode.m"))
    nif = File.read!(Path.join(@root, "ios/mob_nif.m"))

    prop_enum =
      NativeSource.region(
        nif,
        "typedef NS_ENUM(NSUInteger, MobPropKey) {",
        "static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {"
      )
      |> NativeSource.code_only(:objc)

    prop_slots =
      NativeSource.region(
        nif,
        "static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {",
        "static MobNode *mob_node_from_dict(NSDictionary *dict) {"
      )
      |> NativeSource.code_only(:objc)

    node_builder =
      NativeSource.region(
        nif,
        "static MobNode *mob_node_from_dict(NSDictionary *dict) {",
        "static ERL_NIF_TERM nif_exit_app"
      )
      |> NativeSource.code_only(:objc)

    assert header =~ "@property(nonatomic) CGFloat gap;"
    assert implementation =~ "_gap = 0.0"
    assert prop_enum =~ "MOB_PROP_gap"
    assert prop_slots =~ ~s|[MOB_PROP_gap] = @"gap"|
    assert node_builder =~ "id gap = pv[MOB_PROP_gap]"
    assert node_builder =~ "node.gap = [gap doubleValue]"
  end

  test "iOS gives direct row labels priority over flexible spacers" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift")) |> NativeSource.code_only()

    assert source =~ "let prioritizesText = node.childNodes.contains { child in"
    assert source =~ "child.nodeType == .spacer && child.fixedSize <= 0"

    assert source =~
             "prioritizeHorizontalText: prioritizesText"

    assert source =~
             "prioritizeHorizontalText && node.nodeType == .label && node.layoutWeight <= 0 ? 1 : 0"

    assert source =~ "&& lhs.prioritizeHorizontalText == rhs.prioritizeHorizontalText"
  end

  # MOB-181. `MobLayoutWeight` wraps every node with an axis-appropriate
  # `.frame(maxWidth: .infinity, …)` when the node has a positive
  # `layout_weight`. That outer frame is applied AFTER the container case's
  # inner fixed-dim frame, which hides `fixed_width` (or `fixed_height`) on
  # the flexing axis. The fix suppresses the weight-driven max frame when the
  # pinned axis is already fixed, so `fixed` wins over `layout_weight` for
  # iOS internal consistency.
  test "iOS layout weight suppresses maxFrame on the pinned axis" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~ "private struct MobLayoutWeight: ViewModifier {"

    assert source =~
             "            case .horizontal:\n" <>
               "                // MOB-181: a fixed_width on the flexing axis wins over\n" <>
               "                // layout_weight for iOS internal consistency — otherwise\n" <>
               "                // this outer maxWidth: .infinity would hide the inner\n" <>
               "                // .frame(width:) applied by the container case, and the\n" <>
               "                // caller would see fixed_width silently ignored.\n" <>
               "                if node.fixedWidth > 0 {\n" <>
               "                    decorate(content)\n" <>
               "                } else {\n" <>
               "                    decorate(content.frame(maxWidth: .infinity, alignment: .leading))\n" <>
               "                }\n" <>
               "            case .vertical:\n" <>
               "                if node.fixedHeight > 0 {\n" <>
               "                    decorate(content)\n" <>
               "                } else {\n" <>
               "                    decorate(content.frame(maxHeight: .infinity, alignment: .top))\n" <>
               "                }"
  end
end
