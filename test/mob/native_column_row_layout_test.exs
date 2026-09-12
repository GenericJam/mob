# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeColumnRowLayoutTest do
  use ExUnit.Case, async: true

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
             "                MobEitherStack(lazy: lazyContainer, alignment: .leading) {"

    assert source =~
             "                .frame(\n" <>
               "                    width: node.fixedWidth > 0 ? CGFloat(node.fixedWidth) : nil,\n" <>
               "                    height: node.fixedHeight > 0 ? CGFloat(node.fixedHeight) : nil,\n" <>
               "                    alignment: .topLeading\n" <>
               "                )\n" <>
               "                .frame(\n" <>
               "                    maxWidth: node.fixedWidth > 0 ? nil : .infinity,\n" <>
               "                    maxHeight: (node.fillHeight && node.fixedHeight <= 0) ? .infinity : nil,\n" <>
               "                    alignment: .topLeading\n" <>
               "                )"
  end

  # MOB-181. Row previously only honoured `fill_width` and ignored `fixed_width`
  # / `fixed_height` entirely. The fix adds the same inner `.frame(width:height:)`
  # gate as the column case and suppresses the fill_width outer frame when the
  # width axis is already pinned. Anchored to the Row-case HStack opener above
  # it.
  test "iOS row applies fixed_width and fixed_height" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~
             "                HStack(alignment: alignment, spacing: 0) {"

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
