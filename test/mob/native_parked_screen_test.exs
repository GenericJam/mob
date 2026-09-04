defmodule Mob.NativeParkedScreenTest do
  @moduledoc """
  A parked screen stands down; a returning screen wakes up (MOB-147, MOB-145).

  MOB-129 keeps the outgoing screen mounted so popping back diffs rather than
  rebuilds. Before it, "not active" and "not alive" were the same state, so
  nothing had to ask which it was. Several things were wrong by default the
  moment they differed, and a post-merge review found two of them silently
  broken rather than merely wasteful.

  Source-asserted, on comment-stripped source. The stripper here tracks string
  literals and strips trailing comments, because the first version of it did
  neither and a review demonstrated both gaps by leaving an assertion satisfied
  purely by prose.
  """
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest
  use ExUnit.Case, async: true

  @ios File.read!(Path.expand("../../ios/MobRootView.swift", __DIR__))
  @gpu File.read!(Path.expand("../../ios/MobGpuView.swift", __DIR__))
  @nif File.read!(Path.expand("../../ios/mob_nif.m", __DIR__))

  describe "the active-screen signal" do
    test "each slot publishes whether it is the active one" do
      code = code_only(@ios)
      assert code =~ ".environment(\\.mobScreenIsActive, index == activeSlot)"
    end

    test "it defaults to true" do
      # Anything rendered outside a slot — the startup and error branches —
      # must behave as it did before this existed.
      key = region(code_only(@ios), "struct MobScreenIsActiveKey: EnvironmentKey {", "\n}")
      assert key =~ "static let defaultValue: Bool = true"
    end

    test "it is visible outside MobRootView.swift" do
      # MobGpuView.swift is a separate file and reads it. `private` at file
      # scope is fileprivate in Swift, so declaring it private compiles here and
      # fails there.
      code = code_only(@ios)
      refute code =~ "private struct MobScreenIsActiveKey"
      refute code =~ ~r/private extension EnvironmentValues \{[^}]*mobScreenIsActive/s
    end
  end

  describe "the frame registry survives a return (MOB-147 B1)" do
    test "a tracker re-seeds its generation when its slot becomes active" do
      # Without this the change silently breaks the registry for exactly the
      # screens it optimises for. The generation is still bumped on every
      # navigation and stale writes are still refused, but a parked slot's
      # .onAppear never fires again — so a screen you pop back to keeps a stamp
      # two navigations old and every write is rejected for ever.
      tracker = region(code_only(@ios), "private struct MobFrameTracker: ViewModifier {", "\n}\n")

      assert tracker =~ "@Environment(\\.mobScreenIsActive) private var isActive"

      assert tracker =~
               ~r/\.onChange\(of: isActive\) \{ _, nowActive in\s*guard nowActive else \{ return \}\s*box\.generation = mob_frame_generation\(\)/,
             "a returning tracker must re-seed before re-registering"
    end

    test "the generation gate itself is kept" do
      # Dropping the gate would also 'fix' the return path, and would reopen
      # what it exists for: an outgoing screen re-registering at mid-animation
      # coordinates, and two screens sharing an :id clobbering each other.
      code = code_only(@nif)
      assert code =~ "mob_bump_frame_generation();"
      assert code =~ "generation < g_frame_generation"
    end
  end

  describe "cross-screen state does not bleed (MOB-147 B2)" do
    test "the toggle re-seeds from the node" do
      # State(initialValue:) runs once per view identity. MOB-129 keeps
      # identities alive across navigation, so without a sync a toggle inherits
      # the state of whatever toggle sat at the same slot position two
      # navigations back. lib/mob/socket.ex raises ArgumentError on
      # transition: :none for this exact hazard.
      body = region(code_only(@ios), "private struct MobToggle: View {", "\n}\n")
      assert body =~ "onChange(of: node.checked)"
    end

    test "the slider re-seeds from the node" do
      body = region(code_only(@ios), "private struct MobSlider: View {", "\n}\n")
      assert body =~ "onChange(of: node.value)"
    end
  end

  describe "live resources stand down while parked" do
    test "a parked sheet is dismissed and re-presented on return" do
      # .sheet presents on the WINDOW, so the slot's allowsHitTesting(false)
      # does not reach it: a parked sheet would stay visible AND interactive
      # over the incoming screen.
      body = region(code_only(@ios), "private struct MobSheetView: View {", "\n}\n")
      assert body =~ "@Environment(\\.mobScreenIsActive) private var isActive"
      assert body =~ "dismissedByPark"
      assert body =~ ~r/\.onChange\(of: isActive\)/
    end

    test "a park does not report a dismissal to the BEAM" do
      # The screen is coming back, so the sheet is not closed. Reporting it
      # would leave the BEAM believing a sheet it will see again is gone.
      body = region(code_only(@ios), "private func sendDismissOnce() {", "\n    }")
      assert body =~ "if dismissedByPark { return }"
    end

    test "a parked video pauses, and only autoplay resumes it" do
      body =
        region(
          code_only(@ios),
          "func updateUIViewController(_ vc: AVPlayerViewController",
          "\n    }"
        )

      assert body =~ "player.pause()"

      assert body =~ ~r/if autoplay, player\.timeControlStatus == \.paused \{ player\.play\(\) \}/,
             "a video the user paused must stay paused across a park"
    end

    test "a parked GPU view stops rendering" do
      # It runs in continuous mode at 60 fps, so a parked one burns the GPU
      # indefinitely behind the screen the user is looking at.
      body = region(code_only(@gpu), "func updateUIView(_ view: MobGpuMTKView", "\n    }")
      assert body =~ "view.isPaused = !isActive"
    end

    test "the lazy-list latch clears on activation" do
      # MOB-141's latch reasoned that only navigation changes the container's
      # identity. MOB-129 made nothing change it, so a list at the same slot
      # position on a different screen would inherit the previous list's latch.
      body = region(code_only(@ios), "private struct MobLazyList: View {", "\n}\n")

      assert body =~
               ~r/\.onChange\(of: isActive\) \{ _, nowActive in\s*if nowActive \{ firedForCount = nil \}/,
             "clearing on activation restores the pre-MOB-129 behaviour"
    end
  end

  # Strips comments while tracking string literals, so a `//` inside a string
  # survives and a trailing comment cannot satisfy an assertion.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.map(&strip_line/1)
    |> Enum.join("\n")
  end

  defp strip_line(line), do: strip_line(line, <<>>, false)
  defp strip_line(<<>>, acc, _in), do: acc

  defp strip_line(<<"\\", c::utf8, rest::binary>>, acc, true),
    do: strip_line(rest, acc <> <<"\\", c::utf8>>, true)

  defp strip_line(<<"\"", rest::binary>>, acc, in_s),
    do: strip_line(rest, acc <> "\"", not in_s)

  defp strip_line(<<"//", _::binary>>, acc, false), do: acc

  defp strip_line(<<c::utf8, rest::binary>>, acc, in_s),
    do: strip_line(rest, acc <> <<c::utf8>>, in_s)

  defp region(source, from, to) do
    [_, rest] = String.split(source, from, parts: 2)
    [body | _] = String.split(rest, to, parts: 2)
    body
  end
end
