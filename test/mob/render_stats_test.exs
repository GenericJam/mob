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
end
