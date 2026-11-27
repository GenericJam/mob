# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeBoxLayoutTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "iOS box applies a fixed height without a fixed width" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~ "else if node.fixedHeight > 0"
    assert source =~ "stack.frame(height: CGFloat(node.fixedHeight), alignment: alignment)"
    assert source =~ ".frame(maxWidth: .infinity, alignment: alignment)"
  end

  test "iOS box distinguishes explicit fill_width false from the default" do
    header = File.read!(Path.join(@root, "ios/MobNode.h"))
    implementation = File.read!(Path.join(@root, "ios/MobNode.m"))
    nif = File.read!(Path.join(@root, "ios/mob_nif.m"))
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert header =~ "BOOL fillWidthSet"
    assert implementation =~ "_fillWidthSet = NO"
    assert nif =~ "node.fillWidthSet = YES"
    assert source =~ "node.fillWidthSet && !node.fillWidth"
  end

  test "iOS box preserves explicit fill_width false when filling height" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~
             ~r/else if node\.fillHeight \{.*?if node\.fillWidthSet && !node\.fillWidth \{\s*stack\.frame\(maxHeight: \.infinity, alignment: alignment\)/s
  end

  # MOB-568. The fixed-width branch is taken before any fill_height check, so
  # a `width` + `fill_height` box (MishkaSeparator's vertical rule) used to come
  # out 0pt tall. fill_height must apply there too, unless a height is pinned.
  test "iOS box with a fixed width still fills height" do
    source =
      @root
      |> Path.join("ios/MobRootView.swift")
      |> File.read!()
      |> Mob.Test.NativeSource.code_only()
      |> Mob.Test.NativeSource.region(
        "private struct MobBox: View {",
        "} else if node.fixedHeight > 0 {"
      )

    assert source =~ "width: CGFloat(node.fixedWidth)"
    assert source =~ "maxHeight: (node.fillHeight && node.fixedHeight <= 0) ? .infinity : nil"
  end
end
