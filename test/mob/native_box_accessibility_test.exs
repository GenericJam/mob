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

    # Collapse to one element for a label OR an explicit button role. Traits
    # added without collapsing land on every descendant, so a role-only box
    # would announce each nested Text as its own button.
    assert source =~ "node.accessibilityLabel != nil || node.accessibilityRole == \"button\""

    # Kept in its own ViewModifier: inlining these into MobBox's chain pushed
    # it past the Swift type-inference budget and failed the native build,
    # which no Elixir-side check can catch.
    assert source =~ "struct MobBoxSemantics: ViewModifier"
    assert source =~ "isAccessibilityControl ? () : nil"

    # Traits go on as one unconditional OptionSet modifier. Branching on
    # `disabled` would make it a _ConditionalContent boundary and tear down the
    # subtree on every toggle, losing a wrapped TextField's text and focus.
    assert source =~ ".accessibilityAddTraits(traits)"

    # .disabled, not .allowsHitTesting: the latter makes the box transparent
    # to touches, so a disabled backdrop would pass taps through to the
    # content it is meant to be shielding.
    assert source =~ ".disabled(node.disabled)"
    refute source =~ ".allowsHitTesting(!node.disabled)"

    # Tap wiring branches on handler presence only; the disabled check is
    # inside the closure so toggling it is not a structural change.
    assert source =~ ".ifLet(node.onTap)"
    assert source =~ "if !node.disabled { tap() }"
  end
end
