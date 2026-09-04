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

  describe "the mutations a post-merge review proved survived" do
    test "the outgoing slot is cleared in exactly one place, under the release guard" do
      # Inserting `slots[outgoing] = nil` anywhere else destroys depth-1
      # retention — the headline benefit — and every other test still passed.
      # The original guard rejected one exact textual shape; this counts.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      clears = body |> String.split("slots[outgoing] = nil") |> length()

      assert clears - 1 == 1,
             "expected exactly one clear of the outgoing slot, found #{clears - 1}"

      # And it must sit behind the release guard, not anywhere earlier.
      guard_at = index_of(body, "guard releasing, activeSlot != outgoing else { return }")
      clear_at = index_of(body, "slots[outgoing] = nil")
      assert guard_at < clear_at
    end

    test "a resize keeps a parked slot on the side it parked on" do
      # Flipping this sign swings the parked slot on screen after any rotation.
      code = code_only(@ios)
      assert code =~ "slotOffset[i] = slotOffset[i] < 0 ? -width : width"
    end

    test "the slot honours its opacity" do
      # Deleting this makes the reset crossfade machinery dead code while
      # leaving it in the source, which reads as working.
      slot =
        region(code_only(@ios), "private func screenSlot(_ index: Int) -> some View {", "\n    }")

      assert slot =~ ".opacity(slotOpacity[index])"
    end

    test "the startup branch keys on both slots being empty" do
      # `if slots[activeSlot] != nil` looks equivalent and is not: it shows the
      # startup spinner whenever the ACTIVE slot is empty, even though the other
      # slot still holds a screen.
      code = code_only(@ios)
      assert code =~ "if slots[0] != nil || slots[1] != nil"
      refute code =~ "if slots[activeSlot] != nil"
    end

    test "a non-animated navigation still settles" do
      # Dropping settle() from the else branch leaves the incoming screen parked
      # off-screen for any transition with no animation.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")

      assert body =~
               ~r/if let anim = navAnimation\(t\) \{\s*withAnimation\(anim, settle, completion: release\)\s*\} else \{\s*settle\(\)\s*release\(\)\s*\}/,
             "both branches must settle, and both must release"
    end
  end

  describe "the release keys on stack replacement, not the animation (MOB-147 S1)" do
    test "the flag comes from the view model, not from the transition string" do
      # A suffixed atom (`:reset_replace`) was tried and was wrong: the atom's
      # name reaches Android as a raw string and MainActivity.kt matches
      # "push"/"pop"/"reset" with an exact `when`, so a suffixed value fell to
      # `else` and every reset silently lost its animation. Keeping the flag off
      # the transition string keeps that vocabulary closed.
      code = code_only(@ios)
      assert code =~ "replacesStack: model.replacesStack"
      assert code =~ "let releasing = replacesStack"

      refute code =~ "_replace\"",
             "the replacement flag must not ride in the transition string"
    end

    test "the offsets and the animation choice read the transition directly" do
      code = code_only(@ios)

      for fun <- ["enterOffset", "exitOffset", "navAnimation"] do
        body = region(code, "private func #{fun}(", "\n    }")
        assert body =~ "switch t {", "#{fun} should switch on the plain transition"
      end
    end

    test "both opacity seeds derive from the same crossfade decision" do
      # One of the two seeds read the raw transition while the other read a
      # derived value. With a suffixed atom that made a reset cross-fade or
      # hard-cut depending on which slot it landed in. Binding once and using it
      # in both places is what makes that unrepresentable.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      assert body =~ ~s|let crossfading = t == "reset"|
      assert body =~ "slotOpacity[incoming] = crossfading ? 0 : 1"
      assert body =~ "slotOpacity[outgoing] = crossfading ? 0 : 1"

      refute body =~ ~s|slotOpacity[incoming] = (t == "reset")|,
             "the incoming seed must not re-derive the decision"
    end

    test "the release refuses to clear a slot that is now active" do
      # The closure runs on the animation's completion, and a second navigation
      # arriving before it settles reuses the slot it captured — a reset
      # followed quickly by a push makes `outgoing` the ACTIVE slot. Without
      # this guard the release blanks the screen the user is looking at.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      assert body =~ "guard releasing, activeSlot != outgoing else { return }"
    end

    test "the release happens after the animation, not before it" do
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")
      assert body =~ "withAnimation(anim, settle, completion: release)"

      assert body =~ ~r/\} else \{\s*settle\(\)\s*release\(\)\s*\}/,
             "the non-animated branch must settle and release too"
    end
  end

  describe "depth-1 retention" do
    test "push and pop keep the outgoing tree; reset drops it" do
      # Holding the outgoing slot is what makes popping back a diff rather than
      # a rebuild. A reset replaces the stack, so its outgoing screen is
      # unreachable and holding it is pure cost.
      body = region(code_only(@ios), "private func applyRoot(", "\n    }")

      assert body =~
               ~r/guard releasing, activeSlot != outgoing else \{ return \}\s*slots\[outgoing\] = nil/,
             "the outgoing slot is released only for a stack replacement, and only if still parked"
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
      anim = index_of(body, "withAnimation(anim, settle, completion: release)")
      assert seat < anim, "the incoming offset must be seated outside the animation"
    end
  end

  # Strip comments before asserting, so prose next to the code cannot satisfy an
  # assertion. Two defects a review demonstrated in the first version:
  #
  #   * it stripped only FULL-LINE `//` comments, so deleting the real
  #     `containerWidth = width` and leaving the text in a trailing comment left
  #     all 13 tests passing;
  #   * `~r{/\*.*?\*/}s` ran over the whole file, so a string literal containing
  #     `/*` paired with a later `*/` swallowed ~200 lines of real code.
  #
  # Handled line by line, tracking string literals, so a `//` inside a string
  # (a URL, say) survives and a stray `/*` cannot eat the file.
  defp code_only(source) do
    scan(source, :code, [])
  end

  # Scans the whole file as one binary, carrying string and block-comment state
  # ACROSS lines. A per-line scanner reset `in_string` at every newline, which
  # breaks on Swift's multi-line `"""` literals — MobGpuView.swift embeds MSL
  # shader source that way, and a `//` inside it was truncated as if it were a
  # comment. It also never recognised `/* */`, so commented-out code satisfied a
  # `=~` assertion: a false pass, the inverse of the bug this replaced.
  defp scan(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan(<<"\\", c::utf8, rest::binary>>, :string, acc),
    do: scan(rest, :string, [<<c::utf8>>, "\\" | acc])

  defp scan(<<"\"\"\"", rest::binary>>, :code, acc), do: scan(rest, :multiline, ["\"\"\"" | acc])
  defp scan(<<"\"\"\"", rest::binary>>, :multiline, acc), do: scan(rest, :code, ["\"\"\"" | acc])

  defp scan(<<c::utf8, rest::binary>>, :multiline, acc),
    do: scan(rest, :multiline, [<<c::utf8>> | acc])

  defp scan(<<"\"", rest::binary>>, :code, acc), do: scan(rest, :string, ["\"" | acc])
  defp scan(<<"\"", rest::binary>>, :string, acc), do: scan(rest, :code, ["\"" | acc])
  defp scan(<<c::utf8, rest::binary>>, :string, acc), do: scan(rest, :string, [<<c::utf8>> | acc])

  defp scan(<<"//", rest::binary>>, :code, acc), do: scan(rest, :line_comment, acc)
  defp scan(<<"\n", rest::binary>>, :line_comment, acc), do: scan(rest, :code, ["\n" | acc])
  defp scan(<<_::utf8, rest::binary>>, :line_comment, acc), do: scan(rest, :line_comment, acc)

  defp scan(<<"/*", rest::binary>>, :code, acc), do: scan(rest, :block_comment, acc)
  defp scan(<<"*/", rest::binary>>, :block_comment, acc), do: scan(rest, :code, acc)

  defp scan(<<"\n", rest::binary>>, :block_comment, acc),
    do: scan(rest, :block_comment, ["\n" | acc])

  defp scan(<<_::utf8, rest::binary>>, :block_comment, acc), do: scan(rest, :block_comment, acc)

  defp scan(<<c::utf8, rest::binary>>, :code, acc), do: scan(rest, :code, [<<c::utf8>> | acc])

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
