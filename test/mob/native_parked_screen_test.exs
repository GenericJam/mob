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
  import Mob.Test.NativeSource

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
      code = code_only(@nif, :objc)
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

    test "the toggle re-seeds on activation, not only on a value change" do
      # `onChange(of:)` fires on a VALUE change, and slots alternate — screen C
      # reuses screen A's view identities. If both carry `checked == false`, the
      # default, the value never changes and C silently inherits whatever the
      # user toggled on A. That is the common case, and a value watcher alone
      # cannot see it.
      body = region(code_only(@ios), "private struct MobToggle: View {", "\n}\n")
      assert body =~ "@Environment(\\.mobScreenIsActive) private var isActive"

      assert body =~
               ~r/\.onChange\(of: isActive\) \{ _, nowActive in\s*if nowActive, node\.checked != isOn/,
             "the toggle must re-seed when its screen becomes active"
    end

    test "the slider re-seeds on activation too" do
      body = region(code_only(@ios), "private struct MobSlider: View {", "\n}\n")
      assert body =~ "@Environment(\\.mobScreenIsActive) private var isActive"

      assert body =~
               ~r/\.onChange\(of: isActive\) \{ _, nowActive in\s*if nowActive, node\.value != value/
    end

    test "the text field re-seeds on activation and drops focus on park" do
      # `secure: true` renders a SecureField, so an uncontrolled field whose
      # prop is "" on both screens carries a PASSWORD across screens, not just a
      # stale string. And a field holding the keyboard on the outgoing screen
      # must not arrive focused on the incoming one.
      body = region(code_only(@ios), "private struct MobTextField: View {", "\n}\n")
      assert body =~ "@Environment(\\.mobScreenIsActive) private var isActive"

      assert body =~ ~r/guard nowActive else \{\s*isFocused = false/,
             "parking must drop focus"

      assert body =~ ~r/if text != initialText \{\s*text = initialText/
    end

    test "the slider re-seeds from the node" do
      body = region(code_only(@ios), "private struct MobSlider: View {", "\n}\n")
      assert body =~ "onChange(of: node.value)"
    end
  end

  describe "a programmatic re-seed is not reported as a user change (MOB-147 B2)" do
    # `onChange(of:)` sees a value change and nothing about who caused it, so a
    # re-seed on activation would fire the callback on the INCOMING screen — and
    # it fires precisely when the values differ, which is the case the re-seed
    # exists for. The app's handle_event then runs for a control the user never
    # touched.
    #
    # This was first done with a `seeding` latch, armed by the re-seed and
    # cleared by the observed change. That was order-dependent: two programmatic
    # writes straddling one SwiftUI pass left it armed for the wrong write and
    # leaked a change anyway. Comparing against the BEAM's own value is
    # stateless — a re-seed writes exactly that value and so compares equal,
    # while a user's gesture never does.
    for {control, struct_name, watched, from_beam} <- [
          {"toggle", "MobToggle", "isOn", "node.checked"},
          {"slider", "MobSlider", "value", "node.value"},
          {"text field", "MobTextField", "text", "initialText"}
        ] do
      test "the #{control} reports a change only when it differs from the BEAM's value" do
        body = region(code_only(@ios), "private struct #{unquote(struct_name)}: View {", "\n}\n")

        assert body =~
                 ~r/\.onChange\(of: #{unquote(watched)}\) \{ _, newValue in\s*if newValue != #{Regex.escape(unquote(from_beam))} \{/,
               "the change watcher must compare against the BEAM's value"

        refute body =~ "seeding",
               "the order-dependent latch must not come back"
      end
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

    test "a parked video resumes only if it was playing when parked" do
      # Two traps. Gating the resume on `isActive` alone restarts the video on
      # every render, because this runs on every update of the active screen and
      # a fresh node graph arrives on every BEAM render. And gating it on
      # `autoplay` undoes a pause the user made before navigating away: the park
      # finds it already paused and does nothing, the return finds
      # `autoplay && .paused` and plays it.
      #
      # An earlier version of this test asserted exactly that `autoplay` form,
      # with a failure message claiming "a video the user paused must stay
      # paused" — a message asserting a property its own assertion could not
      # detect.
      body =
        region(
          code_only(@ios),
          "func updateUIViewController(_ vc: AVPlayerViewController",
          "\n    }"
        )

      assert body =~ "if context.coordinator.wasPlaying {"

      # Pin the CONDITION, not just the assignment. Relaxing this to a bare
      # `} else {` restores exactly the "did a park happen" semantics this
      # replaced, and every other assertion here still passes.
      assert body =~
               ~r/\} else if player\.timeControlStatus != \.paused \{\s*context\.coordinator\.wasPlaying = true/,
             "only a player that was actually playing may be marked for resume"

      assert body =~ "player.pause()"
    end

    test "a video whose src changed is rebuilt, not resumed" do
      # Slot reuse preserves view identity across DIFFERENT screens, so screen
      # C's video representable can be screen A's — coordinator, player and all.
      # `makeUIViewController` does not run again, so without this C shows A's
      # video, and `wasPlaying` from A's park starts it playing with audio.
      body =
        region(
          code_only(@ios),
          "func updateUIViewController(_ vc: AVPlayerViewController",
          "\n    }"
        )

      assert body =~ ~r/if context\.coordinator\.src != src \{/,
             "a changed src must be detected before anything resumes"

      rebuild = region(body, "if context.coordinator.src != src {", "return")
      assert rebuild =~ "context.coordinator.wasPlaying = false"
      assert rebuild =~ "vc.player = rebuilt"

      # The guard has to come FIRST. Below it, `wasPlaying` resumes a player
      # that may belong to another screen.
      assert index_of(body, "context.coordinator.src != src") <
               index_of(body, "if context.coordinator.wasPlaying {")
    end

    test "the coordinator records playback state, not that a park happened" do
      body = region(code_only(@ios), "final class Coordinator {", "\n    }")
      assert body =~ "var wasPlaying = false"
      assert body =~ "var src: String?"
      refute body =~ "wasParked"
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
end
