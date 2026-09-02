defmodule Mob.RenderStatsTest do
  @moduledoc """
  The measurement infrastructure for MOB-124.

  Every proposal in that epic is gated on these numbers, so a subtly wrong
  meter would send the whole thing in the wrong direction. Tested for the two
  properties that matter: it costs nothing when off, and it counts correctly
  when on.
  """
  use ExUnit.Case, async: false

  alias Mob.RenderStats

  setup do
    RenderStats.disable()
    RenderStats.reset()
    on_exit(fn -> RenderStats.disable() end)
    :ok
  end

  defp frame(overrides \\ %{}) do
    RenderStats.start_frame(Some.Screen, :none)
    RenderStats.time(:render_us, fn -> :ok end)
    Enum.each(overrides, fn {k, v} -> RenderStats.add(k, v) end)
    RenderStats.finish(%{"type" => "text", "props" => %{}, "children" => []}, 42)
  end

  describe "when disabled" do
    test "records nothing" do
      frame()
      assert RenderStats.frames() == []
      assert RenderStats.summary() == %{frames: 0}
    end

    test "time/2 still runs the function and returns its value" do
      # The whole pipeline is wrapped in time/2. If it short-circuited when off,
      # disabling the meter would disable rendering.
      assert RenderStats.time(:render_us, fn -> :computed end) == :computed
    end

    test "leaves nothing in the process dictionary" do
      frame()
      refute Enum.any?(Process.get(), &match?({{Mob.RenderStats, _}, _}, &1))
    end
  end

  describe "when enabled" do
    setup do
      RenderStats.enable()
      :ok
    end

    test "records one frame per finish" do
      frame()
      frame()
      assert length(RenderStats.frames()) == 2
    end

    test "carries the screen and transition" do
      RenderStats.start_frame(My.Screen, :push)
      RenderStats.finish(%{}, 0)

      assert [%{screen: My.Screen, transition: :push}] = RenderStats.frames()
    end

    test "times a stage and stores it" do
      RenderStats.start_frame(Some.Screen, :none)
      RenderStats.time(:encode_us, fn -> Process.sleep(5) end)
      RenderStats.finish(%{}, 0)

      assert [%{encode_us: encode}] = RenderStats.frames()
      assert encode >= 4_000, "expected at least ~5ms, got #{encode}us"
    end

    test "total spans the whole frame, not one stage" do
      RenderStats.start_frame(Some.Screen, :none)
      RenderStats.time(:render_us, fn -> Process.sleep(3) end)
      RenderStats.time(:encode_us, fn -> Process.sleep(3) end)
      RenderStats.finish(%{}, 0)

      assert [%{total_us: total, render_us: render}] = RenderStats.frames()
      assert total > render
    end

    test "frames come back newest first" do
      RenderStats.start_frame(First, :none)
      RenderStats.finish(%{}, 0)
      RenderStats.start_frame(Second, :none)
      RenderStats.finish(%{}, 0)

      assert [%{screen: Second}, %{screen: First}] = RenderStats.frames()
    end

    test "reset/0 discards everything" do
      frame()
      RenderStats.reset()
      assert RenderStats.frames() == []
    end

    test "a frame without start_frame is ignored rather than crashing" do
      # finish/2 runs on every render; if the meter was enabled mid-frame there
      # is no accumulator, and that must not take the screen down.
      assert RenderStats.finish(%{}, 0) == :ok
      assert RenderStats.frames() == []
    end
  end

  describe "counting the prepared tree" do
    setup do
      RenderStats.enable()
      :ok
    end

    defp tree(children), do: %{"type" => "column", "props" => %{}, "children" => children}
    defp leaf(props \\ %{}), do: %{"type" => "text", "props" => props, "children" => []}

    test "counts every node including the root" do
      RenderStats.start_frame(S, :none)
      RenderStats.finish(tree([leaf(), leaf(), tree([leaf()])]), 0)

      assert [%{nodes: 5}] = RenderStats.frames()
    end

    test "counts interactive nodes by their resolved handle" do
      # The renderer has already replaced each handler with an integer handle by
      # the time the tree is counted, which is exactly what register_tap emitted.
      RenderStats.start_frame(S, :none)
      RenderStats.finish(tree([leaf(%{"on_tap" => 0}), leaf(), leaf(%{"on_change" => 3})]), 0)

      assert [%{taps: 2}] = RenderStats.frames()
    end

    test "an unresolved handler is not counted as a tap" do
      # -1 is the pool-exhausted sentinel, and a raw pid means prepare never ran.
      RenderStats.start_frame(S, :none)
      RenderStats.finish(tree([leaf(%{"on_tap" => -1}), leaf(%{"on_tap" => self()})]), 0)

      assert [%{taps: 1}] = RenderStats.frames(), "only the integer handle counts"
    end

    test "records the payload size it was given" do
      RenderStats.start_frame(S, :none)
      RenderStats.finish(tree([]), 4096)

      assert [%{bytes: 4096}] = RenderStats.frames()
    end
  end

  describe "summary/0" do
    setup do
      RenderStats.enable()
      :ok
    end

    test "reports percentiles rather than a mean" do
      # Frame cost is not normally distributed and the tail is what a user feels
      # as stutter, so the summary has to surface it.
      for us <- [1, 1, 1, 1, 1, 1, 1, 1, 1, 500] do
        RenderStats.start_frame(S, :none)
        RenderStats.add(:render_us, us)
        RenderStats.finish(%{}, 0)
      end

      summary = RenderStats.summary()
      assert summary.frames == 10
      assert summary.stages.render_us.p50 == 1
      assert summary.stages.render_us.max == 500
    end

    test "p50 is the median and p95 is not just the maximum" do
      # Ranks, on distinct values, so an off-by-one cannot hide. The previous
      # version of this file used nine identical values and could not fail.
      # `round/1` instead of `ceil/1` gives p50 == 11 and p95 == 20 here: every
      # reported median one rank high, and every p95 equal to the single worst
      # frame for any run under ~21 frames.
      for us <- 1..20 do
        RenderStats.start_frame(S, :none)
        RenderStats.add(:render_us, us)
        RenderStats.finish(%{}, 0)
      end

      %{p50: p50, p95: p95, max: max} = RenderStats.summary().stages.render_us

      assert p50 == 10
      assert p95 == 19
      assert max == 20
    end

    test "percentiles exclude frames that were never committed" do
      # A dropped frame never ran prepare/encode/set_root and its total_us is
      # mostly queueing. Pooling it with real frames makes a p50 that describes
      # neither, and `bytes: 0` for a drop would drag the byte percentiles to
      # zero while still reading as a measurement.
      RenderStats.start_frame(S, :none)
      RenderStats.add(:render_us, 100)
      RenderStats.finish(%{}, 5000)

      for _ <- 1..9 do
        RenderStats.start_frame(S, :none)
        RenderStats.add(:render_us, 1)
        RenderStats.drop_frame(RenderStats.take_frame())
      end

      summary = RenderStats.summary()

      assert summary.frames == 10
      assert summary.committed == 1
      assert summary.dropped == 9
      assert summary.bytes == %{p50: 5000, p95: 5000, max: 5000}
      assert summary.stages.render_us.p50 == 100
      assert %{p50: _, p95: _, max: _} = summary.dropped_total_us
    end

    test "lists the screens measured" do
      RenderStats.start_frame(A, :none)
      RenderStats.finish(%{}, 0)
      RenderStats.start_frame(B, :none)
      RenderStats.finish(%{}, 0)

      assert Enum.sort(RenderStats.summary().screens) == [A, B]
    end

    test "a stage never recorded is nil rather than zero" do
      # Zero would read as "this stage is free", which is a different claim.
      RenderStats.start_frame(S, :none)
      RenderStats.add(:render_us, 10)
      RenderStats.finish(%{}, 0)

      assert RenderStats.summary().stages.set_root_us == nil
    end
  end

  describe "a frame that crosses the screen/sender boundary" do
    # The bug this exists to prevent: paint/4 opens the frame in the SCREEN
    # process, then hands the tree to Mob.Sender as a cast, so prepare, encode
    # and set_root run in the SENDER process. A process-dictionary accumulator
    # does not travel, and the first version of this module recorded nothing at
    # all on device because of it.
    defmodule StubNif do
      def clear_taps, do: :ok
      def set_transition(_), do: :ok
      def register_tap(_), do: 0
      def set_root(_json), do: :ok
    end

    setup do
      for name <- [Mob.Sender], pid = Process.whereis(name), do: GenServer.stop(pid)
      {:ok, sender} = Mob.Sender.start_link(active: :the_screen)
      on_exit(fn -> if Process.alive?(sender), do: GenServer.stop(sender) end)

      RenderStats.enable()
      RenderStats.reset()
      :ok
    end

    defp paint_from_another_process(ref) do
      # Stands in for Mob.Screen.Server.paint/4: time the screen-side stages,
      # hand the frame over, then cast the render — from a process that is not
      # the sender.
      task =
        Task.async(fn ->
          RenderStats.start_frame(Some.Screen, :none)
          RenderStats.time(:render_us, fn -> :ok end)
          RenderStats.hand_off(ref)
          Mob.Sender.render(ref, %{type: :text, props: %{}, children: []}, :ios, StubNif, :none)
        end)

      Task.await(task)
      Mob.Sender.sync()
    end

    test "the frame survives the hand-off and records every stage" do
      paint_from_another_process(:the_screen)

      assert [frame] = RenderStats.frames()
      assert frame.screen == Some.Screen
      assert frame.committed == true

      for stage <- [:render_us, :prepare_us, :encode_us, :set_root_us] do
        assert is_integer(Map.get(frame, stage)),
               "#{stage} missing — the frame did not survive the process hop"
      end
    end

    test "records the payload the sender actually encoded" do
      paint_from_another_process(:the_screen)
      assert [%{bytes: bytes, nodes: 1}] = RenderStats.frames()
      assert bytes > 0
    end

    test "a tree the sender drops is recorded as uncommitted, not lost" do
      # Its BEAM-side cost was paid either way; a pipeline throwing away half its
      # work is a finding rather than a detail.
      paint_from_another_process(:some_other_screen)

      assert [%{committed: false, screen: Some.Screen}] = RenderStats.frames()
    end
  end

  describe "through the real paint path" do
    # The test above proves the hand-off mechanism works. This one proves
    # Mob.Screen.Server.paint/4 actually uses it — removing the hand_off call
    # from paint/4 passes the mechanism test and fails this one, which is the
    # difference between testing a function and testing the system.
    defmodule RealNif do
      def platform, do: :android
      def safe_area, do: {0.0, 0.0, 0.0, 0.0}
      def take_launch_notification, do: :none
      def clear_taps, do: :ok
      def set_transition(_), do: :ok
      def register_tap(_), do: 0
      def set_root(_json), do: :ok
    end

    defmodule CounterScreen do
      use Mob.Screen
      def mount(_p, _s, socket), do: {:ok, Mob.Socket.assign(socket, :n, 0)}

      def render(assigns) do
        %{type: :text, props: %{text: "n=#{assigns.n}"}, children: []}
      end

      def handle_event("bump", _, socket),
        do: {:noreply, Mob.Socket.assign(socket, :n, socket.assigns.n + 1)}
    end

    defmodule DemoApp do
      @behaviour Mob.App
      import Mob.App
      def navigation(_), do: stack(:home, root: Mob.RenderStatsTest.CounterScreen)
    end

    setup do
      services = [Mob.Sender, Mob.Listener, Mob.ComponentRegistry, Mob.Nav.Registry]
      for name <- services, pid = Process.whereis(name), do: safe_stop(pid)

      {:ok, _} = Mob.ComponentRegistry.start_link()
      {:ok, _} = Mob.Nav.Registry.start_link(DemoApp)

      RenderStats.enable()
      RenderStats.reset()

      {:ok, router} = Mob.Router.start_root(CounterScreen, %{}, nif: RealNif)

      on_exit(fn ->
        safe_stop(router)
        for name <- services, pid = Process.whereis(name), do: safe_stop(pid)
      end)

      %{router: router}
    end

    defp safe_stop(pid) do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    test "a real render records a complete frame", %{router: router} do
      RenderStats.reset()
      Mob.Screen.dispatch(router, "bump", %{})
      Mob.Sender.sync()

      assert [frame | _] = RenderStats.frames()
      assert frame.screen == CounterScreen
      assert frame.committed == true
      assert frame.nodes == 1

      for stage <- [:render_us, :expand_us, :reconcile_us, :prepare_us, :encode_us, :set_root_us] do
        assert is_integer(Map.get(frame, stage)),
               "#{stage} was not recorded through the real paint path"
      end
    end
  end

  describe "bounded storage" do
    test "keeps the most recent frames and drops the oldest" do
      # A long measurement session on a memory-constrained device must not grow
      # without limit.
      RenderStats.enable()

      for i <- 1..520 do
        RenderStats.start_frame(:"s#{i}", :none)
        RenderStats.finish(%{}, 0)
      end

      frames = RenderStats.frames()
      assert length(frames) <= 500
      assert hd(frames).screen == :s520, "newest must survive"
    end
  end

  describe "tap counting" do
    setup do
      RenderStats.enable()
      :ok
    end

    defp node_with(props), do: %{"type" => "row", "props" => props, "children" => []}

    test "counts register_tap calls, not interactive nodes" do
      # One node carrying three handlers makes three NIF calls. Counting nodes
      # reported 1 here, which made `taps` disagree with `register_tap_us_n`
      # and put the per-call cost derived from it out by the same factor.
      RenderStats.start_frame(S, :none)

      RenderStats.finish(
        node_with(%{"on_tap" => 1, "on_long_press" => 2, "on_double_tap" => 3}),
        0
      )

      assert [%{taps: 3}] = RenderStats.frames()
    end

    test "counts the scroll and swipe handlers the renderer registers" do
      # These nine were missing from the original prop set, so any scrolling
      # screen — the exact case MOB-128 is about — undercounted silently.
      props =
        Map.new(
          ~w(on_swipe_left on_swipe_right on_swipe_up on_swipe_down on_scroll_began
             on_scroll_ended on_scroll_settled on_top_reached on_scrolled_past),
          &{&1, 7}
        )

      RenderStats.start_frame(S, :none)
      RenderStats.finish(node_with(props), 0)

      assert [%{taps: 9}] = RenderStats.frames()
    end

    test "agrees with the count accumulate/2 observes" do
      # The two are independent: one walks the finished tree, the other counts
      # calls as they happen. They are in the same summary, so a disagreement
      # means one is wrong and nobody can tell which.
      RenderStats.start_frame(S, :none)
      for _ <- 1..3, do: RenderStats.accumulate(:register_tap_us, fn -> :ok end)
      RenderStats.finish(node_with(%{"on_tap" => 1, "on_change" => 2, "on_blur" => 3}), 0)

      assert [%{taps: 3, register_tap_us_n: 3}] = RenderStats.frames()
    end
  end

  describe "recording stops when disabled mid-frame" do
    test "finish/2 records nothing and leaves no frame behind" do
      # Only time/2 checked the flag, so an operator who disabled the meter
      # kept getting records for any frame already in flight.
      RenderStats.enable()
      RenderStats.start_frame(S, :none)
      RenderStats.disable()
      RenderStats.finish(%{}, 777)

      RenderStats.enable()
      assert RenderStats.frames() == []
      assert RenderStats.take_frame() == nil
    end

    test "accumulate/2 still runs the function" do
      RenderStats.enable()
      RenderStats.start_frame(S, :none)
      RenderStats.disable()
      assert RenderStats.accumulate(:register_tap_us, fn -> :computed end) == :computed
    end
  end

  describe "resume_frame/1" do
    setup do
      RenderStats.enable()
      :ok
    end

    test "clears a leftover frame rather than no-opping" do
      # A render that raises skips finish/2 and leaves its frame in the process
      # dictionary. Treating resume_frame(nil) as a no-op let that frame be
      # closed against the next tree, producing one record spanning two frames
      # whose total_us is mostly the gap between them.
      # No start_frame in between: that is the shape of the real path. The
      # sender resumes whatever frame the screen handed it — nil, when the
      # previous render raised before hand_off — and then commits, and the
      # commit's finish/2 is what closes the frame in the pdict.
      RenderStats.start_frame(StaleScreen, :push)
      RenderStats.add(:render_us, 999)

      RenderStats.resume_frame(nil)
      RenderStats.finish(%{"type" => "text", "props" => %{}, "children" => []}, 1234)

      assert RenderStats.frames() == []
    end
  end
end
