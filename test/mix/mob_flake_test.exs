defmodule Mix.Tasks.Mob.FlakeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Flake

  # `mix mob.flake` exists to surface rare failures. If its own parser drops
  # one, the tool reports green and the flake stays hidden — a worse outcome
  # than not having the tool, because it launders a guess into a verdict. Two
  # versions of this parser had exactly that bug (a sliding window that
  # discarded the last block; a fallback made unreachable by an earlier match),
  # so the property under test throughout is: nothing is lost.

  defp block(name, mod, i) do
    line = i * 10

    [
      "  #{i}) test #{name} (#{mod})",
      "     test/some/path_test.exs:#{line}",
      "     Assertion with == failed",
      "     code:  assert foo() == :bar",
      "     left:  :baz",
      "     right: :bar",
      "     stacktrace:",
      "       test/some/path_test.exs:#{line}: (test)"
    ]
    |> Enum.join("\n")
  end

  defp run_output(failures) do
    blocks =
      failures
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{name, mod}, i} -> block(name, mod, i) end)

    """
    Compiling 1 file (.ex)
    ....

    #{blocks}

    Finished in 0.4 seconds (0.2s async, 0.2s sync)
    #{length(failures) + 4} tests, #{length(failures)} failures

    Randomized with seed 123456
    """
  end

  describe "failing_tests/1" do
    test "reports every failure, including the last one" do
      out =
        run_output([
          {"alpha does a thing", "My.FirstTest"},
          {"beta does another", "My.SecondTest"},
          {"gamma is last", "My.ThirdTest"}
        ])

      extract = Flake.failing_tests(out)

      # The last block is the one both previous implementations lost.
      assert extract =~ "alpha does a thing"
      assert extract =~ "beta does another"
      assert extract =~ "gamma is last"
    end

    test "keeps the whole failure body rather than truncating it" do
      extract = Flake.failing_tests(run_output([{"alpha", "My.Test"}]))

      # A fixed line cap cut ordinary failures off mid-stacktrace, which is the
      # part that says *where*.
      assert extract =~ "Assertion with == failed"
      assert extract =~ "left:  :baz"
      assert extract =~ "stacktrace:"
      assert extract =~ "test/some/path_test.exs:10: (test)"
    end

    test "stops at ExUnit's summary instead of absorbing it" do
      extract = Flake.failing_tests(run_output([{"alpha", "My.Test"}]))

      refute extract =~ "Finished in",
             "the run summary is the noise this function exists to strip"

      refute extract =~ "Randomized with seed"
      refute extract =~ "tests, 1 failures"
    end

    test "falls back to the tail when the run died before any failure block" do
      # A compile error produces no `1) test ...` header at all. Returning "" here
      # would report a failing run with no explanation.
      out = """
      == Compilation error in file lib/broken.ex ==
      ** (SyntaxError) unexpected token
          lib/broken.ex:12
      """

      extract = Flake.failing_tests(out)

      assert extract =~ "Compilation error"
      assert extract =~ "SyntaxError"
    end

    test "hands back the tail when a run has no failure blocks at all" do
      clean = "....\n\nFinished in 0.1 seconds\n4 tests, 0 failures\n"

      # Not "": a caller looking at this had a reason to, so show the run's end
      # rather than an empty string that says nothing about why.
      assert Flake.failing_tests(clean) =~ "4 tests, 0 failures"
    end

    test "returns empty for empty input rather than raising" do
      assert Flake.failing_tests("") == ""
    end
  end
end
