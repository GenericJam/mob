defmodule Mob.NativeScreenSlotsTest do
  @moduledoc """
  Navigation preserves view identity instead of destroying it (MOB-129).

  The root used to carry `.id(currentNavVersion)`, which destroyed and rebuilt
  the whole tree on every push, pop and reset. Measured on a 1614-node screen: a
  navigation cost 235 ms against a 65.7 ms steady-state re-render, and the entire
  169 ms gap was the identity change. Two fixed slots that ping-pong, with the
  slide driven by an offset rather than by `.transition()`, brought a navigation
  to 76 ms.

  Source-asserted because there is no host-side way to run SwiftUI. Every
  assertion runs on comment-stripped source: the region being guarded is heavily
  commented with the very words being matched, so an assertion a comment could
  satisfy would pass against code that does nothing.
  """
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest
  use ExUnit.Case, async: true

  @ios File.read!(Path.expand("../../ios/MobRootView.swift", __DIR__))

  describe "identity" do
    test "navigation no longer changes the root's identity" do
      # The entire measured win. `.id(currentNavVersion)` is what cost 169 ms.
      code = code_only(@ios)

      refute code =~ ".id(currentNavVersion)",
             "the nav-version identity is what this issue removed"

      refute code =~ "@State private var currentNavVersion",
             "and the state backing it should be gone too"
    end

    test "the slots carry no .id() at all" do
      # Their fixed structural position in the ZStack IS their identity. Adding
      # an .id() back, even a stable one, re-opens the door to identity churn.
      slot =
        region(code_only(@ios), "private func screenSlot(_ index: Int) -> some View {", "\n    }")

      refute slot =~ ".id(", "a slot must take its identity from its position"
    end

    test "the transition modifier is gone" do
      # `.transition()` only fires on insert/remove, and insert/remove is exactly
      # what costs 169 ms. Keeping it would mean keeping the teardown.
      code = code_only(@ios)
      refute code =~ ".transition(navTransition", "transition() requires insert/remove"
      refute code =~ "private func navTransition", "and its helper is dead"
    end
  end

  describe "the two slots" do
    test "there are exactly two, and one is active" do
      code = code_only(@ios)
      assert code =~ "@State private var slots: [MobNode?] = [nil, nil]"
      assert code =~ "@State private var activeSlot: Int = 0"
      assert code =~ "screenSlot(0)"
      assert code =~ "screenSlot(1)"
    end

    test "a navigation ping-pongs rather than reusing the active slot" do
      # Writing the incoming tree into the ACTIVE slot would diff it over the
      # outgoing screen: no second tree to animate, so no transition, and the
      # retention below becomes impossible.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      assert body =~ "let incoming = 1 - activeSlot"
      assert body =~ "let outgoing = activeSlot"
      assert body =~ "slots[incoming] = newRoot"
      assert body =~ "activeSlot = incoming"
    end

    test "a none render updates the active slot in place" do
      # The steady-state path. Ping-ponging here would make every ordinary
      # re-render a navigation, which is the bug inverted.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")

      assert body =~ ~r/guard t != "none" else \{\s*slots\[activeSlot\] = newRoot\s*return\s*\}/,
             "a none render must write the active slot and return"
    end
  end

  describe "depth-1 retention" do
    test "push and pop keep the outgoing tree; reset drops it" do
      # Holding the outgoing slot is what makes popping back a diff rather than
      # a rebuild. A reset replaces the stack, so its outgoing screen is
      # unreachable and holding it is pure cost.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")

      assert body =~ ~r/if t == "reset" \{\s*slots\[outgoing\] = nil/,
             "reset must release the outgoing slot"

      refute body =~ ~r/slots\[outgoing\] = nil\s*\n\s*\}\s*\n\s*\}\s*\z/,
             "push and pop must NOT clear the outgoing slot"
    end
  end

  describe "the parked slot is cheap and inert" do
    test "the slot root is wrapped in an equality check" do
      # Without this the parked slot's subtree is re-evaluated on every render of
      # the active one, and holding it costs more than rebuilding it.
      slot =
        region(code_only(@ios), "private func screenSlot(_ index: Int) -> some View {", "\n    }")

      assert slot =~ ".equatable()"
    end

    test "equality is reference identity, not content" do
      # Every interactive node's handle prop is (generation << 12) | slot and
      # clear_taps bumps the generation every render, so a content comparison is
      # false for any subtree containing a tappable node. Reference identity is
      # the only comparison that can ever be true.
      eq = region(code_only(@ios), "extension MobNodeView: Equatable {", "\n}")
      assert eq =~ "lhs.node === rhs.node"
      refute eq =~ "lhs.node ==  rhs.node"
      refute eq =~ "isEqual"
    end

    test "the parked slot cannot be tapped" do
      # SwiftUI hit-tests over its own display list and does not necessarily
      # honour zero opacity the way UIKit honours zero alpha. A tappable parked
      # screen would resolve handles from a superseded tap-table generation.
      slot =
        region(code_only(@ios), "private func screenSlot(_ index: Int) -> some View {", "\n    }")

      assert slot =~ ".allowsHitTesting(index == activeSlot)"
      assert slot =~ ".accessibilityHidden(index != activeSlot)"
    end
  end

  describe "the slide" do
    test "distance comes from real geometry, not the screen" do
      # UIScreen.bounds is wrong under split view, Stage Manager and rotation,
      # which would leave a parked screen partly visible.
      code = code_only(@ios)
      assert code =~ "containerWidth = width"
      refute code =~ "UIScreen.main.bounds.width"
    end

    test "push and pop enter and exit on opposite sides" do
      enter = region(code_only(@ios), "private func enterOffset(", "\n    }")
      exit_ = region(code_only(@ios), "private func exitOffset(", "\n    }")

      assert enter =~ ~r/case "push": return containerWidth/
      assert enter =~ ~r/case "pop": return -containerWidth/
      assert exit_ =~ ~r/case "push": return -containerWidth/
      assert exit_ =~ ~r/case "pop": return containerWidth/
    end

    test "the incoming tree is seated before the animation, not inside it" do
      # Seating inside withAnimation would animate the placement itself, so the
      # incoming screen would slide from wherever it last sat rather than from
      # off-screen.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      seat = index_of(body, "slotOffset[incoming] = enterOffset(t)")
      anim = index_of(body, "withAnimation(animation, settle)")
      assert seat < anim, "the incoming offset must be seated outside the animation"
    end
  end

  defp code_only(source) do
    source
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r{^\s*//.*$}, ""))
    |> Enum.join("\n")
  end

  defp region(source, from, to) do
    [_, rest] = String.split(source, from, parts: 2)
    [body | _] = String.split(rest, to, parts: 2)
    body
  end

  defp index_of(hay, needle) do
    case :binary.match(hay, needle) do
      {i, _} -> i
      :nomatch -> flunk("expected to find #{inspect(needle)}")
    end
  end
end
