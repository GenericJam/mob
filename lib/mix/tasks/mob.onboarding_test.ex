defmodule Mix.Tasks.Mob.OnboardingTest do
  @shortdoc "Run the Mob onboarding integration test suite"

  @moduledoc """
  Runs the Mob onboarding integration tests, which verify that a new user can
  go from zero to a running app without hitting any friction that should have
  been caught automatically.

  ## Usage

      mix mob.onboarding_test                 # pre-device tests only (fast)
      mix mob.onboarding_test --all           # all tests including post-device
      mix mob.onboarding_test --only generator
      mix mob.onboarding_test --only failure_modes
      mix mob.onboarding_test --only pre_device
      mix mob.onboarding_test --only post_device

  ## Options

      --all           Run all onboarding tests, including those that need a
                      booted iOS simulator or Android emulator
      --only TAG      Run only tests with this tag
      --env ENV       Toolchain environment to report in output (mise|asdf|nix|brew)
      --seed N        ExUnit seed (passed through to mix test)
      --no-color      Disable ANSI colors in output

  ## What this runs

  Tests live in `test/onboarding/` and are tagged `:onboarding`. They are
  excluded from the normal `mix test` run to avoid slowing down the development
  loop.

  Sub-tags:
  - `:generator`      — Stage 1–4: archive install, project gen, install, doctor
  - `:failure_modes`  — All failure injection tests
  - `:pre_device`     — Failure tests that require no simulator/emulator
  - `:post_device`    — Failure tests that require a running simulator/emulator

  ## Workspace isolation

  Each test creates a fresh temp directory under `/tmp/mob_onboarding_<id>/`
  with its own MIX_HOME, HEX_HOME, and MOB_CACHE_DIR. On success the workspace
  is deleted. On failure it is preserved and its path is printed so you can
  inspect logs and the generated project.
  """

  use Mix.Task

  @switches [
    all: :boolean,
    only: :string,
    env: :string,
    seed: :integer,
    no_color: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    include_tags = build_include_tags(opts)
    test_args = build_test_args(opts, include_tags)

    banner(opts)
    System.put_env("MIX_ENV", "test")

    exit_code =
      Mix.shell().cmd("mix test test/onboarding/ #{Enum.join(test_args, " ")}")

    if exit_code != 0, do: Mix.raise("Onboarding tests failed (exit #{exit_code})")
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_include_tags(opts) do
    # Tags use simple atoms (:generator, :pre_device, etc.) combined with the
    # module-level :onboarding tag. --only overrides the global exclusion of
    # :onboarding so all onboarding subtests get included.
    cond do
      opts[:all] -> ["onboarding"]
      opts[:only] -> [opts[:only]]
      true -> ["generator", "pre_device"]
    end
  end

  defp build_test_args(opts, include_tags) do
    args = Enum.flat_map(include_tags, fn tag -> ["--only", tag] end)
    args = if seed = opts[:seed], do: args ++ ["--seed", "#{seed}"], else: args
    args = if opts[:no_color], do: args ++ ["--no-color"], else: args
    args
  end

  defp banner(opts) do
    env_label = opts[:env] || "default"
    scope = if opts[:all], do: "all tests", else: opts[:only] || "generator + pre-device"

    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════╗
    ║         Mob Onboarding Integration Tests             ║
    ║  Scope: #{String.pad_trailing(scope, 44)}║
    ║  Env:   #{String.pad_trailing(env_label, 44)}║
    ╚══════════════════════════════════════════════════════╝
    """)
  end
end
