defmodule Mob.NativeFrameStatsTest do
  @moduledoc """
  Native frame timing: the half `Mob.RenderStats` could not see (MOB-126).

  `set_root_us` closes when `nif_set_root` returns, and that is the moment the
  tree is handed to the main thread, not the moment it is on screen. The
  SwiftUI build, layout and display all happen afterwards, so the native half
  of every frame was unmeasured. MOB-129 and MOB-130 are both explicitly
  evidence-gated, and there was no evidence to gate them on.

  The Swift and ObjC halves are asserted against source text because there is
  no host-side way to run them. Every such assertion goes through `code_only/1`
  first: an earlier test in this repo passed by matching a string that appeared
  only inside its own explanatory comment, which is a test that guards nothing.
  """
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest
  use ExUnit.Case, async: true

  alias Mob.RenderStats

  @view_model File.read!(Path.expand("../../ios/MobViewModel.swift", __DIR__))
  @nif File.read!(Path.expand("../../ios/mob_nif.m", __DIR__))
  @erl File.read!(Path.expand("../../src/mob_nif.erl", __DIR__))

  # A NIF module that has not been loaded: every function raises, which is what
  # a device whose native half predates this feature actually does.
  defmodule NotLoadedNif do
    def native_stats, do: :erlang.nif_error(:not_loaded)
    def native_stats_enable(_on), do: :erlang.nif_error(:not_loaded)
  end

  # No such functions at all: the host, where :mob_nif does not exist.
  defmodule AbsentNif do
  end

  defmodule FakeNif do
    def native_stats_enable(_on), do: :ok

    def native_stats do
      ~s({"enabled":true,"recorded":5,"dropped":0,"samples":[) <>
        ~s({"apply_us":9000.0,"transition":"push","seq":4},) <>
        ~s({"apply_us":7000.0,"transition":"push","seq":3},) <>
        ~s({"apply_us":5000.0,"transition":"push","seq":2},) <>
        ~s({"apply_us":300.0,"transition":"none","seq":1},) <>
        ~s({"apply_us":100.0,"transition":"none","seq":0}]})
    end
  end

  describe "graceful degradation" do
    test "a native half that has not implemented it reports :unsupported" do
      # Android has no native_stats yet, so :mob_nif keeps the Erlang stub and
      # it raises. Reading stats must not take down whatever is reading them.
      assert {:error, :unsupported} = RenderStats.native_enable(NotLoadedNif)
      assert {:error, :unsupported} = RenderStats.native_disable(NotLoadedNif)
      assert {:error, :unsupported} = RenderStats.native_frames(NotLoadedNif)
      assert {:error, :unsupported} = RenderStats.native_summary(NotLoadedNif)
    end

    test "the host, with no NIF module at all, reports :unsupported" do
      assert {:error, :unsupported} = RenderStats.native_enable(AbsentNif)
      assert {:error, :unsupported} = RenderStats.native_summary(AbsentNif)
    end
  end

  describe "native_summary/1" do
    test "splits percentiles by transition rather than pooling them" do
      # The whole point of the measurement. A "none" sample re-renders into an
      # existing view tree; a "push" rebuilds it because the root takes a new
      # identity. Pooling the two produces a p50 that describes neither, and
      # the size of the gap is what MOB-126 and MOB-129 argue about.
      summary = RenderStats.native_summary(FakeNif)

      assert %{"push" => push, "none" => none} = summary.apply_us
      assert push.n == 3
      assert none.n == 2
      assert push.max == 9000.0
      assert none.max == 300.0
      assert push.p50 > none.p50
    end

    test "carries recorded and dropped so a percentile can be read honestly" do
      summary = RenderStats.native_summary(FakeNif)

      assert summary.samples == 5
      assert summary.recorded == 5
      assert summary.dropped == 0
    end

    test "an empty window is not an error" do
      defmodule EmptyNif do
        def native_stats, do: ~s({"enabled":true,"recorded":0,"dropped":0,"samples":[]})
      end

      assert %{samples: 0, recorded: 0} = RenderStats.native_summary(EmptyNif)
    end

    test "malformed native JSON does not raise" do
      defmodule GarbageNif do
        def native_stats, do: "not json at all"
      end

      assert {:error, :bad_json} = RenderStats.native_frames(GarbageNif)
    end
  end

  describe "the iOS measurement" do
    test "is gated so a disabled app pays only the enabled check" do
      # The gate is the entire cost argument. Without it every set_root arms a
      # run loop observer and takes two timestamps, on the main thread, in
      # every shipped app that never asked to measure anything.
      code = code_only(@view_model)
      assert code =~ "mob_native_stats_enabled()"

      assert code =~ ~r/let measuring = mob_native_stats_enabled\(\) != 0/,
             "setRoot must decide up front whether it is measuring"

      assert code =~ ~r/if measuring \{\s*self\.measureApply/,
             "the observer must only be armed when measuring"
    end

    test "closes on run loop idle, not on the CATransaction that was open" do
      # CATransaction.setCompletionBlock is the obvious choice and is wrong:
      # SwiftUI's update routinely lands in a later transaction than the one
      # open at assignment time, so the completion fires before the work being
      # measured has happened, and the measurement reads near zero.
      code = code_only(@view_model)
      assert code =~ "CFRunLoopActivity.beforeWaiting"

      refute code =~ "setCompletionBlock",
             "a CATransaction completion closes before SwiftUI has built the tree"
    end

    test "the observer removes itself" do
      # repeats: false invalidates it, but an observer left added to the run
      # loop is a leak per set_root, and this is on the main thread.
      code = code_only(@view_model)
      assert code =~ "CFRunLoopRemoveObserver"
      assert code =~ ~r/CFRunLoopObserverCreateWithHandler\([^)]*/s
    end

    test "records the transition alongside the duration" do
      # Without it the two populations cannot be separated on read, and the
      # summary above is impossible.
      assert code_only(@view_model) =~ ~r/mob_record_native_frame\(.*, transition\)/
    end
  end

  describe "the native half" do
    test "both NIFs are registered in the function table" do
      code = code_only(@nif)
      assert code =~ ~s({"native_stats", 0, nif_native_stats,)
      assert code =~ ~s({"native_stats_enable", 1, nif_native_stats_enable,)
    end

    test "the disabled path is an atomic load and nothing else" do
      # If the enabled flag were guarded by the sample lock instead, every
      # set_root in every app would take a lock the NIF thread also takes.
      code = code_only(@nif)
      assert code =~ "_Atomic int g_native_stats_enabled"
      assert code =~ "atomic_load_explicit(&g_native_stats_enabled, memory_order_relaxed)"
    end

    test "the reader snapshots under the lock and encodes outside it" do
      # Same reasoning as nif_element_frames: the main thread takes this lock
      # once per set_root, and JSON-encoding the window from a dirty scheduler
      # while holding it stalls UI work on a thread with no QoS relationship.
      #
      # Asserted against the actual @synchronized block rather than against a
      # nearby line. The earlier version located the closing brace by looking
      # for the text that happened to follow it, which passed just as happily
      # with the memcpy hoisted ABOVE the lock (the regression it is named for)
      # and failed on an innocent rename or an added comment.
      critical = synchronized_body(nif_body(@nif, "nif_native_stats"))

      assert critical =~ "memcpy(snapshot, g_native_frames",
             "the copy must happen inside @synchronized"

      refute critical =~ "NSJSONSerialization",
             "the encode must not happen while the lock is held"

      assert nif_body(@nif, "nif_native_stats") =~ "NSJSONSerialization",
             "and it must still happen somewhere"
    end

    test "the Swift-callable helpers are outside the debug-only harness guard" do
      # MobViewModel calls both on every set_root with no knowledge of
      # MOB_RELEASE: the release pipeline compiles ios/*.swift without the flag
      # and mob_nif.m with it. Defining these inside the guard links in debug
      # and fails EVERY release build with an undefined symbol. Only the two
      # NIFs that read the samples belong inside.
      code = code_only(@nif)

      writer_at = index_of(code, "void mob_record_native_frame(double apply_us")
      probe_at = index_of(code, "int mob_native_stats_enabled(void) {")
      harness_at = index_of(code, "#if !MOB_RELEASE // resume the debug-only harness")

      assert writer_at < harness_at,
             "mob_record_native_frame is Swift-callable and must not be release-gated"

      assert probe_at < harness_at,
             "mob_native_stats_enabled is Swift-callable and must not be release-gated"

      # The readers, by contrast, must stay gated: they are harness surface.
      assert index_of(code, "static ERL_NIF_TERM nif_native_stats(") > harness_at
    end
  end

  describe "the measurement's closing bracket" do
    test "the observer runs after Core Animation's commit, not before it" do
      # beforeWaiting observers fire in ascending order, and Core Animation's
      # transaction-commit observer sits at 2000000. SwiftUI evaluates bodies
      # and lays out inside that commit, so an observer at order 0 fires before
      # every bit of the work being measured and still reports a plausible
      # number. This is the same class of silent-wrong-answer as the
      # CATransaction completion the module rejects, and it has to be pinned
      # rather than left to a comment.
      assert code_only(@view_model) =~ "CFIndex.max"

      refute code_only(@view_model) =~ ~r/beforeWaiting\.rawValue,\s*false,\s*0\b/s,
             "order 0 puts the bracket ahead of the layout being measured"
    end
  end

  describe "reading a payload from a mismatched native half" do
    test "a samples field that is not a list is refused, not crashed on" do
      defmodule ScalarSamplesNif do
        def native_stats, do: ~s({"enabled":true,"recorded":1,"dropped":0,"samples":5})
      end

      assert {:error, {:unexpected_payload, _}} = RenderStats.native_frames(ScalarSamplesNif)
      assert {:error, {:unexpected_payload, _}} = RenderStats.native_summary(ScalarSamplesNif)
    end

    test "samples that are not maps are refused" do
      defmodule BareSamplesNif do
        def native_stats, do: ~s({"enabled":true,"recorded":3,"dropped":0,"samples":[1,2,3]})
      end

      assert {:error, {:unexpected_payload, _}} = RenderStats.native_summary(BareSamplesNif)
    end

    test "a non-numeric duration cannot take over the tail" do
      # Elixir term ordering puts every binary above every number, so one bad
      # value becomes both p95 and max: it captures exactly the half of the
      # distribution the measurement exists to look at.
      defmodule StringDurationNif do
        def native_stats do
          ~s({"enabled":true,"recorded":2,"dropped":0,"samples":[) <>
            ~s({"apply_us":"slow","transition":"push","seq":1},) <>
            ~s({"apply_us":3.0,"transition":"push","seq":0}]})
        end
      end

      summary = RenderStats.native_summary(StringDurationNif)
      assert %{"push" => push} = summary.apply_us
      assert push.n == 1
      assert push.max == 3.0
    end

    test "a genuine error from a working NIF is not disguised as :unsupported" do
      # rescue ErlangError across the board would turn a real failure inside a
      # loaded NIF into "this platform does not support it", which reads as
      # nothing being wrong.
      defmodule AngryNif do
        def native_stats, do: :erlang.error(:system_limit)
      end

      assert_raise SystemLimitError, fn -> RenderStats.native_frames(AngryNif) end
    end

    test "enabling clears the window so a run cannot report an earlier one" do
      assert nif_body(@nif, "nif_native_stats_enable") =~ "g_native_frame_seq = 0"
    end

    test "the ring buffer reports what scrolled out of it" do
      # A p95 over 240 samples of a 5000-sample run describes the tail only.
      # Without `dropped` the reader has no way to know that happened.
      assert code_only(@nif) =~ ~r/@"dropped" : @\(total > MOB_NATIVE_FRAME_SAMPLES/
    end
  end

  describe "the Erlang stub" do
    test "declares both functions as NIFs, not just exports" do
      # A function exported but absent from -nifs stays the Erlang stub after
      # load_nif, so it raises for ever with no error at load time. This repo
      # has shipped that exact bug before.
      code = code_only(@erl)
      [exports, nifs] = String.split(code, "-nifs([", parts: 2)

      assert exports =~ "native_stats/0"
      assert exports =~ "native_stats_enable/1"
      assert nifs =~ "native_stats/0"
      assert nifs =~ "native_stats_enable/1"
    end
  end

  # Strip comments before asserting. Written because an assertion that a
  # comment can satisfy guards nothing, and this repo has been bitten by it:
  # a test grepped for a string that existed only in the comment explaining
  # the test. Handles Swift/ObjC `//` and `/* */`, and Erlang `%%`.
  defp code_only(source) do
    source
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.replace(~r{^\s*//.*$}, "")
      |> String.replace(~r{^\s*%%.*$}, "")
    end)
    |> Enum.join("\n")
  end

  # The text between `@synchronized(lock) {` and its matching close, by brace
  # depth. Locating the close by the line that follows it is what made the
  # earlier version of the lock test pass with the memcpy hoisted out.
  defp synchronized_body(body) do
    [_, after_open] = String.split(body, "@synchronized(lock) {", parts: 2)

    {taken, _} =
      after_open
      |> String.graphemes()
      |> Enum.reduce_while({[], 1}, fn
        "{", {acc, depth} -> {:cont, {["{" | acc], depth + 1}}
        "}", {acc, 1} -> {:halt, {acc, 0}}
        "}", {acc, depth} -> {:cont, {["}" | acc], depth - 1}}
        c, {acc, depth} -> {:cont, {[c | acc], depth}}
      end)

    taken |> Enum.reverse() |> Enum.join()
  end

  defp nif_body(source, name) do
    code = code_only(source)
    [_, after_decl] = String.split(code, "static ERL_NIF_TERM #{name}(", parts: 2)
    [body | _] = String.split(after_decl, "\nstatic ", parts: 2)
    body
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("expected to find #{inspect(needle)}")
    end
  end
end
