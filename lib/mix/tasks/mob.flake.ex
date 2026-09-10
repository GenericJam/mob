defmodule Mix.Tasks.Mob.Flake do
  @shortdoc "Run the suite repeatedly to surface flaky tests"

  @moduledoc """
  Run the test suite until it fails, or a set number of times, and report
  which tests were not deterministic.

  A flake does not announce itself. It fails once, on someone else's branch,
  and the natural response is to re-run and move on — which is how a 1-in-17
  failure survived long enough to corrupt a mutation-testing verdict and send
  a bisect down the wrong path. This makes looking cheap and deliberate.

      mix mob.flake                    # 20 runs, stop at the first failure
      mix mob.flake --runs 50          # more attempts
      mix mob.flake --until-failure    # keep going until one fails
      mix mob.flake --keep-going       # run them all, report every failure
      mix mob.flake test/mob/nav       # narrow the target
      mix mob.flake --seed 0           # fix the seed, so ordering is constant

  ## Reading the result

  A test that fails under `--seed 0` on every run is not flaky, it is broken.
  This looks for the other kind: tests that pass and fail with everything else
  held still. Those are almost always a race — a `Process.sleep` standing in
  for synchronisation, a check-then-act across a process boundary, or shared
  global state (a named process, an ETS table) whose lifetime is tied to
  whichever test happened to start it.

  Narrowing helps more than volume. If a failure names one module, run that
  module 200 times rather than the suite 20 more times.
  """

  use Mix.Task

  @switches [runs: :integer, until_failure: :boolean, keep_going: :boolean, seed: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, paths} = OptionParser.parse!(argv, strict: @switches)

    runs = Keyword.get(opts, :runs, 20)
    until_failure? = Keyword.get(opts, :until_failure, false)
    keep_going? = Keyword.get(opts, :keep_going, false)
    limit = if until_failure?, do: :infinity, else: runs

    Mix.shell().info([
      :cyan,
      "Running the suite #{describe(limit)}, ",
      if(keep_going?, do: "reporting every failure.", else: "stopping at the first failure."),
      :reset
    ])

    loop(1, limit, keep_going?, opts, paths, [])
  end

  defp describe(:infinity), do: "until it fails"
  defp describe(n), do: "#{n} time(s)"

  defp loop(attempt, limit, keep_going?, opts, paths, failures) do
    if limit != :infinity and attempt > limit do
      report(attempt - 1, failures)
    else
      case run_once(opts, paths) do
        :ok ->
          IO.write(".")
          loop(attempt + 1, limit, keep_going?, opts, paths, failures)

        {:failed, output} ->
          IO.write("F")
          failures = [{attempt, output} | failures]

          if keep_going? and limit != :infinity do
            loop(attempt + 1, limit, keep_going?, opts, paths, failures)
          else
            report(attempt, failures)
          end
      end
    end
  end

  defp run_once(opts, paths) do
    args =
      ["test"] ++
        paths ++
        case Keyword.fetch(opts, :seed) do
          {:ok, seed} -> ["--seed", to_string(seed)]
          :error -> []
        end

    # Fresh OS process per run, deliberately: an in-process re-run would share
    # the ETS tables and named processes that cause most of these failures, so
    # it could not reproduce them.
    {output, status} = System.cmd("mix", args, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    if status == 0, do: :ok, else: {:failed, output}
  end

  defp report(runs, []) do
    Mix.shell().info([:green, "\n\n#{runs} run(s), no failures.", :reset])

    Mix.shell().info([
      "\nThat is evidence, not proof. A 1-in-17 flake survives 20 green runs ",
      "about 30% of the time — narrow the target and raise --runs before ",
      "concluding a suspected flake is gone."
    ])
  end

  defp report(runs, failures) do
    ordered = Enum.reverse(failures)

    Mix.shell().error("\n\n#{length(ordered)} failure(s) in #{runs} run(s):\n")

    # Always write the full log to disk, not just the summarised extract. A rare
    # failure may not come back: it is entirely possible to watch one go past,
    # fail to reproduce it in a hundred later runs, and be left with nothing to
    # go on because the only copy was a summary on a terminal that scrolled.
    # That happened while building this task. The artefact costs nothing and is
    # the difference between a lead and a rumour.
    dir = Path.join([Mix.Project.build_path(), "mob_flake"])
    File.mkdir_p!(dir)

    for {attempt, output} <- ordered do
      path = Path.join(dir, "run-#{attempt}.log")
      File.write!(path, output)

      Mix.shell().error("── run #{attempt} " <> String.duplicate("─", 50))
      Mix.shell().error(failing_tests(output))
      Mix.shell().info([:faint, "   full log: #{Path.relative_to_cwd(path)}", :reset])
    end

    Mix.shell().info([
      "\nRe-run the named module alone, many times, before changing anything. ",
      "A failure that only appears in the full suite is usually shared global ",
      "state, not the test's own logic."
    ])

    exit({:shutdown, 1})
  end

  # The whole log is noise; what matters is which tests failed and why.
  #
  # Split on failure headers rather than sliding a window over the lines. A
  # window silently loses any failure near the end of the output — and because
  # an earlier match makes the fallback unreachable, it loses it without saying
  # so. For a tool that exists to surface rare failures, that is the worst
  # possible bug, and it was in the first version of this function.
  @header ~r/^\s+\d+\) (test|doctest|property) /

  # ExUnit's own trailer. A failure block runs until this, not to the end of the
  # log — otherwise the last one absorbs the summary and the seed line, which is
  # exactly the noise this function exists to strip.
  @summary ~r/^(Finished in |\d+ (test|doctest|property)|Randomized with seed )/

  @doc false
  @spec failing_tests(String.t()) :: String.t()
  def failing_tests(output) do
    output
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      cond do
        Regex.match?(@header, line) -> [{:open, [line]} | acc]
        acc == [] -> acc
        match?([{:closed, _} | _], acc) -> acc
        Regex.match?(@summary, line) -> [{:closed, elem(hd(acc), 1)} | tl(acc)]
        true -> [{:open, [line | elem(hd(acc), 1)]} | tl(acc)]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_, block} ->
      block |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing()
    end)
    |> case do
      [] -> output |> String.split("\n") |> Enum.take(-15) |> Enum.join("\n")
      blocks -> Enum.join(blocks, "\n\n")
    end
  end
end
