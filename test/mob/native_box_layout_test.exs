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
end
