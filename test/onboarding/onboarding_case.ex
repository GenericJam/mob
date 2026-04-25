defmodule Mob.Onboarding.Case do
  @moduledoc """
  ExUnit case template for onboarding integration tests.

  Provides:
  - A unique workspace per test (created in setup, destroyed on success)
  - Shell.run/2 wrappers with logging
  - Custom assertions for file structure, shell output, and app state
  - Automatic workspace preservation on failure

  Usage:

      defmodule MyOnboardingTest do
        use Mob.Onboarding.Case

        test "generates a valid project", %{ws: ws} do
          result = shell("mix mob.new my_app", ws)
          assert_success result
          assert_file ws, "my_app/mix.exs"
        end
      end

  All tests are tagged `@moduletag :onboarding` and are excluded from
  `mix test` by default. Run them with:

      mix test --only onboarding
      mix test --only onboarding:generator       # generator-only (no device)
      mix test --only onboarding:failure_modes   # failure injection tests
  """

  use ExUnit.CaseTemplate

  alias Mob.Onboarding.Shell
  alias Mob.Onboarding.Workspace

  using do
    quote do
      import Mob.Onboarding.Case

      alias Mob.Onboarding.Shell
      alias Mob.Onboarding.Workspace
      alias Mob.Onboarding.DeviceManager
      alias Mob.Onboarding.FailureInjector

      @moduletag :onboarding
    end
  end

  setup context do
    run_id = unique_id(context)
    ws = Workspace.create(run_id)

    # on_exit runs in a different OS process than the test, so Process.put/get
    # cannot communicate pass/fail status. Use an unlinked Agent instead — it
    # survives test process termination and is readable from on_exit.
    {:ok, flag} = Agent.start(fn -> false end)
    Process.put(:onboarding_passed_agent, flag)

    on_exit(fn ->
      passed = Agent.get(flag, & &1)
      Agent.stop(flag)

      if passed do
        Workspace.destroy(ws)
      else
        Workspace.preserve(ws, :test_failed)
      end
    end)

    {:ok, ws: ws}
  end

  # ── Shell helpers ─────────────────────────────────────────────────────────────

  @doc """
  Run a command in the workspace root, log it, and return the Shell result.
  """
  def shell(command, %Workspace{} = ws, opts \\ []) do
    result = Shell.run(command, Workspace.shell_opts(ws, opts))
    Workspace.log_step(ws, step_name(command), result)
    result
  end

  @doc """
  Run a command inside the generated project directory.
  """
  def shell_project(command, %Workspace{} = ws, opts \\ []) do
    result = Shell.run(command, Workspace.project_opts(ws, opts))
    Workspace.log_step(ws, step_name(command), result)
    result
  end

  # ── Assertions ────────────────────────────────────────────────────────────────

  @doc "Assert the Shell result exited 0."
  def assert_success(%Shell{} = r) do
    unless Shell.success?(r) do
      Process.put(:onboarding_failure_reason, {:command_failed, r.command, r.exit_code})
      Shell.assert_success!(r)
    end

    r
  end

  @doc "Assert the output contains the given string or matches the regex."
  def assert_output(%Shell{} = r, pattern) do
    unless Shell.output_contains?(r, pattern) do
      flunk("""
      Expected output of `#{r.command}` to contain #{inspect(pattern)}

      Actual output:
      #{r.output}
      """)
    end

    r
  end

  @doc "Assert the output does NOT contain the given string or regex."
  def refute_output(%Shell{} = r, pattern, opts \\ []) do
    if Shell.output_contains?(r, pattern) do
      msg =
        opts[:message] || "Expected output of `#{r.command}` NOT to contain #{inspect(pattern)}"

      flunk("""
      #{msg}

      Actual output:
      #{r.output}
      """)
    end

    r
  end

  @doc "Assert a file exists inside the workspace."
  def assert_file(%Workspace{root: root}, rel_path) do
    full = Path.join(root, rel_path)

    unless File.exists?(full) do
      flunk("Expected file to exist: #{full}")
    end

    full
  end

  @doc "Assert a directory exists inside the workspace."
  def assert_dir(%Workspace{root: root}, rel_path) do
    full = Path.join(root, rel_path)

    unless File.dir?(full) do
      flunk("Expected directory to exist: #{full}")
    end

    full
  end

  @doc "Assert a file's content matches a string or regex."
  def assert_file_contains(%Workspace{root: root}, rel_path, pattern) do
    full = Path.join(root, rel_path)
    content = File.read!(full)

    unless content_matches?(content, pattern) do
      flunk("""
      Expected #{rel_path} to contain #{inspect(pattern)}

      Actual content (first 500 chars):
      #{String.slice(content, 0, 500)}
      """)
    end

    content
  end

  @doc "Assert a file's content does NOT contain the pattern."
  def refute_file_contains(%Workspace{root: root}, rel_path, pattern) do
    full = Path.join(root, rel_path)
    content = File.read!(full)

    if content_matches?(content, pattern) do
      flunk("Expected #{rel_path} NOT to contain #{inspect(pattern)}")
    end

    content
  end

  @doc """
  Assert that `mix mob.doctor` output contains a passing check for `item`.
  Checks for the ✓ prefix.
  """
  def assert_doctor_pass(%Shell{} = r, item) do
    assert_output(r, ~r/✓.*#{Regex.escape(item)}/)
  end

  @doc """
  Assert that `mix mob.doctor` output contains a failing check for `item`.
  Checks for the ✗ prefix.
  """
  def assert_doctor_fail(%Shell{} = r, item) do
    assert_output(r, ~r/✗.*#{Regex.escape(item)}/)
  end

  @doc """
  Assert that `mix mob.doctor` output contains a warning for `item`.
  Checks for the ⚠ prefix.
  """
  def assert_doctor_warn(%Shell{} = r, item) do
    assert_output(r, ~r/⚠.*#{Regex.escape(item)}/)
  end

  @doc """
  Write `mob.exs` before running `mix mob.install` so the interactive path
  configuration prompt is skipped. Points `mob_dir` at the project's own
  `deps/mob` directory (which is already fetched by `mix mob.new`).

  Call this after `Workspace.set_project/2` and before `shell_project("mix mob.install", ...)`.
  """
  def configure_mob_exs(%Workspace{project_dir: nil}),
    do: raise("call Workspace.set_project/2 before configure_mob_exs/1")

  def configure_mob_exs(%Workspace{project_dir: project_dir} = ws) do
    mob_dir = Path.join(project_dir, "deps/mob")
    path = Path.join(project_dir, "mob.exs")

    File.write!(path, """
    import Config

    # Pre-configured for automated onboarding tests. mob_dir points to the
    # local :mob dep so mix mob.install skips the interactive path prompt.
    config :mob_dev,
      mob_dir: #{inspect(mob_dir)}
    """)

    ws
  end

  @doc "Mark the test as passed — call at the end of every successful test."
  def mark_passed do
    case Process.get(:onboarding_passed_agent) do
      # shouldn't happen, but don't crash if setup didn't run
      nil -> :ok
      agent -> Agent.update(agent, fn _ -> true end)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp unique_id(context) do
    test_name =
      context.test |> to_string() |> String.replace(~r/[^a-z0-9]+/i, "_") |> String.downcase()

    short = String.slice(test_name, -20..-1//1)
    "#{short}_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp step_name(command) do
    command
    |> String.split()
    |> Enum.take(3)
    |> Enum.join("_")
    |> String.replace(~r/[^a-z0-9_]/i, "")
  end

  defp content_matches?(content, %Regex{} = re), do: content =~ re
  defp content_matches?(content, str) when is_binary(str), do: String.contains?(content, str)
end
