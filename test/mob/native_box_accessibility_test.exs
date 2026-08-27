# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeBoxAccessibilityTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "iOS parses box accessibility state at the native boundary" do
    header = File.read!(Path.join(@root, "ios/MobNode.h"))
    nif = File.read!(Path.join(@root, "ios/mob_nif.m"))

    assert header =~ "NSString *accessibilityLabel"
    assert header =~ "NSString *accessibilityRole"
    assert header =~ "BOOL disabled"
    assert nif =~ ~s|props[@"accessibility_label"]|
    assert nif =~ "node.accessibilityLabel = accessibilityLabel"
    assert nif =~ ~s|props[@"accessibility_role"]|
    assert nif =~ "node.accessibilityRole = accessibilityRole"
    assert nif =~ ~s|props[@"disabled"]|
    assert nif =~ "node.disabled = [disabled boolValue]"
  end

  test "iOS box exposes one labeled action and suppresses disabled input" do
    source = File.read!(Path.join(@root, "ios/MobRootView.swift"))

    assert source =~ ".accessibilityElement(children: .ignore)"
    assert source =~ "view.accessibilityLabel(label)"
    assert source =~ ~s|node.accessibilityRole == "button"|
    assert source =~ ".accessibilityAddTraits(.isButton)"
    assert source =~ ".accessibilityAddTraits(.isNotEnabled)"
    assert source =~ ".allowsHitTesting(!node.disabled)"
    assert source =~ ".ifLet(node.disabled ? nil : node.onTap)"
  end
end
