# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeBoxLayoutTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "iOS box applies a fixed height without a fixed width" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~
             "            } else if node.fixedHeight > 0 {\n" <>
               "                stack\n" <>
               "                    .frame(height: CGFloat(node.fixedHeight), " <>
               "alignment: alignment)\n" <>
               "                    .frame(maxWidth: .infinity, alignment: alignment)\n" <>
               "            } else if node.fillHeight {\n"
  end
end
