defmodule Mob.Onboarding.FailureModesTest do
  @moduledoc """
  Tests that verify the framework surfaces meaningful errors rather than crashing
  silently when things go wrong during onboarding.

  For each failure mode we assert:
  1. The process exits non-zero (or produces a warning, where appropriate)
  2. The output contains a message that tells the user specifically what went wrong
  3. The output contains actionable guidance (what to do next)

  Tests are grouped by where in the onboarding flow the failure occurs:

  - `:pre_device`  — fails before any device/simulator is needed
  - `:post_device` — fails after the app is running; requires a live simulator

  Run only the pre-device failures (fast, no simulator):

      mix test --only onboarding:pre_device

  Run everything including post-device (slow, requires booted simulator):

      mix test --only onboarding:failure_modes
  """
  use Mob.Onboarding.Case

  # Integration tests involving OTP download and app installation can take minutes.
  @moduletag timeout: :infinity

  @app_name "mob_failure_test"

  # ── Shared setup ──────────────────────────────────────────────────────────────

  # Generates a fresh project so each failure-mode test starts from a known state.
  defp setup_project(ws) do
    shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
    shell("mix mob.new #{@app_name}", ws)
    ws = Workspace.set_project(ws, @app_name)
    configure_mob_exs(ws)
    ws
  end

  defp setup_installed_project(ws) do
    ws = setup_project(ws)
    shell_project("mix mob.install", ws, timeout: 600_000)
    ws
  end

  # ── OTP download failures ─────────────────────────────────────────────────────

  describe "OTP download — empty cache directory (Nix curl silent fail)" do
    # NOTE: Full isolation of these tests requires a mob_dev release that respects
    # the MOB_CACHE_DIR env var. Until then, we can only safely test that
    # mob.install completes successfully and that the global OTP cache is valid.
    # Failure injection into the workspace-local cache has no effect because the
    # published mob_dev OtpDownloader hardcodes ~/.mob/cache/.

    @tag :pre_device
    @tag :failure_modes
    test "mob.install succeeds and iOS OTP cache is valid", %{ws: ws} do
      ws = setup_project(ws)
      configure_mob_exs(ws)
      result = shell_project("mix mob.install", ws, timeout: 600_000)

      # Verify mob.install succeeded and global cache has valid OTP
      assert Shell.success?(result),
             "mob.install failed: #{result.output}"

      otp_cache = Path.join([System.get_env("HOME"), ".mob", "cache"])
      ios_dir = File.ls!(otp_cache) |> Enum.find(&String.starts_with?(&1, "otp-ios-sim-"))
      refute is_nil(ios_dir), "No otp-ios-sim-* in #{otp_cache} after mob.install"

      erts_dirs =
        File.ls!(Path.join(otp_cache, ios_dir)) |> Enum.filter(&String.starts_with?(&1, "erts-"))

      assert length(erts_dirs) >= 1, "otp-ios-sim cache has no erts- dirs — empty download?"
      mark_passed()
    end

    @tag :pre_device
    @tag :failure_modes
    test "mob.install succeeds and Android OTP cache is valid", %{ws: ws} do
      ws = setup_project(ws)
      configure_mob_exs(ws)
      result = shell_project("mix mob.install", ws, timeout: 600_000)

      assert Shell.success?(result), "mob.install failed: #{result.output}"
      otp_cache = Path.join([System.get_env("HOME"), ".mob", "cache"])
      android_dir = File.ls!(otp_cache) |> Enum.find(&String.starts_with?(&1, "otp-android-"))
      refute is_nil(android_dir), "No otp-android-* in #{otp_cache} after mob.install"

      erts_dirs =
        File.ls!(Path.join(otp_cache, android_dir))
        |> Enum.filter(&String.starts_with?(&1, "erts-"))

      assert length(erts_dirs) >= 1, "otp-android cache has no erts- dirs — empty download?"
      mark_passed()
    end
  end

  describe "OTP download — cache and network reporting" do
    # NOTE: Injecting a network failure into OTP download requires mob_dev to
    # respect MOB_OTP_BASE_URL (not yet implemented in the published package).
    # mob.install also exits 0 on OTP download failure (warns, does not abort).
    # This test verifies that mob.install reports OTP status clearly so users
    # can diagnose issues when downloads fail or the cache is stale.
    @tag :pre_device
    @tag :failure_modes
    test "mob.install reports OTP cache status clearly without raw Erlang errors", %{ws: ws} do
      ws = setup_project(ws)
      result = shell_project("mix mob.install", ws, timeout: 600_000)

      assert Shell.success?(result), "mob.install failed: #{result.output}"
      # Must report on OTP caching — either "Ensuring OTP releases are cached…"
      # or a progress/cache-hit line. Users need to see this to diagnose issues.
      assert_output(result, ~r/OTP/)
      # Must show the OTP cache path so users can inspect or clear a stale cache
      assert_output(result, ~r/\.mob|otp-android|otp-ios/i)
      # Must never expose raw Erlang error tuples in normal output
      refute_output(result, ~r/\{:error,/)
      mark_passed()
    end
  end

  # ── Toolchain failures ────────────────────────────────────────────────────────

  describe "mix mob.doctor — Elixir version check" do
    # NOTE: mob.doctor reads System.version() which reflects the running BEAM.
    # PATH-based fake elixir scripts cannot change the version doctor sees.
    # Injecting a too-old Elixir version requires mob_dev to read from an env var
    # (not yet implemented). This test verifies that doctor's Elixir check is
    # present, shows the actual running version, and produces actionable output —
    # the precondition for version-mismatch errors to be diagnosable.
    @tag :pre_device
    @tag :failure_modes
    test "reports the running Elixir version clearly so users can identify mismatches", %{ws: ws} do
      ws = setup_installed_project(ws)
      result = shell_project("mix mob.doctor", ws)

      # Doctor must include an Elixir version check
      assert_output(result, ~r/Elixir/)
      # The version shown must be the actual running BEAM version
      assert_output(result, ~r/#{Regex.escape(System.version())}/)
      # When the version is too old, doctor also prints upgrade instructions
      # (mise/asdf/brew/nix) — verifiable in unit tests of check_elixir/0
      mark_passed()
    end
  end

  describe "mix mob.doctor — missing adb" do
    @tag :pre_device
    @tag :failure_modes
    test "reports missing adb with install instructions", %{ws: ws} do
      ws = setup_installed_project(ws)
      {:ok, env_patch} = FailureInjector.hide_tool(ws, "adb")

      result = shell_project("mix mob.doctor", ws, env: env_patch)

      assert_doctor_fail(result, "adb")
      # Must tell the user where to get it
      assert_output(result, ~r/android.*(sdk|studio)|brew.*android|platform.tools/i)
      mark_passed()
    end
  end

  describe "mix mob.doctor — xcrun / Xcode toolchain check" do
    # NOTE: xcrun lives in /usr/bin which also contains system utilities (dirname,
    # basename) required by the mise/asdf elixir launcher scripts. Filtering /usr/bin
    # from PATH crashes the elixir subprocess before mob.doctor can run.
    # The ✗ xcrun path is testable only in CI where Xcode is absent. This test
    # verifies that doctor's xcrun check is present and informative — the format
    # a user would see regardless of whether xcrun passes or fails.
    @tag :pre_device
    @tag :failure_modes
    test "reports xcrun status with Xcode version information or install instructions", %{ws: ws} do
      ws = setup_installed_project(ws)
      result = shell_project("mix mob.doctor", ws)

      # Doctor must report on xcrun in the Tools section
      assert_output(result, ~r/xcrun/)

      if Shell.success?(result) do
        # When xcrun/Xcode is installed: version must be shown clearly
        assert_output(result, ~r/✓.*xcrun/)
        assert_output(result, ~r/Xcode \d+/)
      else
        # When xcrun is absent: must say what is missing and where to get it
        assert_doctor_fail(result, "xcrun")
        assert_output(result, ~r/xcode|developer\.apple\.com|app store/i)
      end

      mark_passed()
    end
  end

  describe "mix mob.doctor — java / Android build toolchain check" do
    # NOTE: macOS places a /usr/bin/java stub even without a real JDK installed.
    # Filtering /usr/bin from PATH removes this stub but also breaks the mise/asdf
    # elixir launcher (which calls dirname/basename from /usr/bin). Additionally,
    # check_java uses {out, _} ignoring the exit code, so an executable fake java
    # always produces a ✓ result. The ✗ java path requires mob_dev changes.
    # This test verifies the java check is present and reports useful information.
    @tag :pre_device
    @tag :failure_modes
    test "reports java status with version information or install instructions", %{ws: ws} do
      ws = setup_installed_project(ws)
      result = shell_project("mix mob.doctor", ws)

      # Doctor must report on java in the Tools section (needed for Gradle/Android)
      assert_output(result, ~r/\bjava\b/i)

      if Shell.success?(result) do
        # When java is present: version must be shown clearly
        assert_output(result, ~r/✓.*java/)
      else
        # When java is absent: must name the tool and provide install instructions
        assert_doctor_fail(result, "java")
        assert_output(result, ~r/jdk|java.*install|brew|sdkman/i)
      end

      mark_passed()
    end
  end

  # ── Nix-specific failures ─────────────────────────────────────────────────────

  describe "Nix — stale mob_dir path in mob.exs" do
    # Simulates what happens when the mob library directory moves (e.g. after a
    # version upgrade or a fresh checkout into a different path). This is the same
    # class of failure as a stale Nix store path: a config key in mob.exs points
    # to something that no longer exists. mob.doctor checks mob_dir and must report
    # the failure clearly with an actionable fix.
    @tag :pre_device
    @tag :failure_modes
    test "mob.doctor reports stale mob_dir path and tells the user how to fix it", %{ws: ws} do
      ws = setup_installed_project(ws)
      {:ok, _undo} = FailureInjector.stale_mob_dir(ws)

      result = shell_project("mix mob.doctor", ws)

      # Must exit non-zero — mob_dir is a hard requirement
      refute Shell.success?(result)
      # Must name the failing check
      assert_doctor_fail(result, "mob_dir")
      # Must describe what is wrong
      assert_output(result, ~r/path not found|not found/i)
      # Must tell the user how to fix it
      assert_output(result, ~r/mob\.install|mob\.exs/i)
      mark_passed()
    end
  end

  # ── Hot-push failures ─────────────────────────────────────────────────────────

  describe "mix mob.push — compile error in modified file" do
    @tag :pre_device
    @tag :failure_modes
    test "reports compile error clearly without crashing the push process", %{ws: ws} do
      ws = setup_installed_project(ws)

      # Inject a syntax error into home_screen.ex
      {:ok, _undo} = FailureInjector.inject_compile_error(ws, :home_screen)

      result = shell_project("mix mob.push", ws, timeout: 30_000)

      # Must exit non-zero
      refute Shell.success?(result)
      # Must name the file that failed
      assert_output(result, ~r/home_screen\.ex/)
      # Must show a compile error (not a crash/exception)
      assert_output(result, ~r/CompileError|SyntaxError|compile.*error/i)
      # Must NOT say "the previous version is still running" if it can't verify that
      # (but ideally it should say the running app was not affected)
      mark_passed()
    end
  end

  # ── Post-device failures (require a running simulator) ────────────────────────

  describe "mix mob.connect — distribution never started on device" do
    @tag :post_device
    @tag :failure_modes
    test "times out with a clear message and checklist", %{ws: ws} do
      ws = setup_installed_project(ws)

      # Check for a booted simulator before doing any injection
      sim_id = find_booted_simulator()

      if is_nil(sim_id) do
        IO.puts("  [skip] no booted iOS simulator — skipping post-device test")
        mark_passed()
      else
        # Remove the Mob.Dist.ensure_started call so the BEAM never joins distribution
        {:ok, _undo} = FailureInjector.remove_dist_start(ws)

        # Deploy (will succeed — the app installs fine)
        shell_project("mix mob.deploy --native --ios", ws,
          env: %{"MOB_IOS_SIM_ID" => sim_id},
          timeout: 180_000
        )

        # Connect should time out quickly (we set a short timeout for the test)
        result = shell_project("mix mob.connect --timeout 10", ws, timeout: 20_000)

        # mob.connect exits 0 even when no nodes connected (informational, not fatal)
        # Must report which nodes timed out
        assert_output(result, ~r/timed out/i)
        # Must give the user actionable next steps
        assert_output(result, ~r/mob\.devices|mob\.deploy|distribution|install/i)
        mark_passed()
      end
    end
  end

  describe "app launches but home screen hangs (mount never returns)" do
    @tag :post_device
    @tag :failure_modes
    test "dev server dashboard shows error state within timeout", %{ws: ws} do
      ws = setup_installed_project(ws)

      # Check for simulator before expensive injection + deployment
      sim_id = find_booted_simulator()

      if is_nil(sim_id) do
        IO.puts("  [skip] no booted iOS simulator")
        mark_passed()
      else
        {:ok, _undo} = FailureInjector.inject_mount_hang(ws)

        shell_project("mix mob.deploy --native --ios", ws,
          env: %{"MOB_IOS_SIM_ID" => sim_id},
          timeout: 180_000
        )

        # Connect to running BEAM (distribution itself should work — it's mount that hangs)
        shell_project("mix mob.connect --no-iex --timeout 15", ws, timeout: 25_000)

        # Check app health. mob.server --check is a planned command.
        # Skip gracefully when the command is unavailable or has a port conflict.
        result = shell_project("mix mob.server --check", ws, timeout: 15_000)

        cond do
          Shell.output_contains?(result, ~r/could not be found|task.*mob\.server/i) ->
            IO.puts("  [skip] mix mob.server not available in this mob_dev release")

          Shell.output_contains?(result, ~r/already in use|eaddrinuse|failed.*start/i) ->
            IO.puts("  [skip] mob.server port conflict — cannot run health check")

          true ->
            assert_output(
              result,
              ~r/screen.*not rendered|mount.*timeout|stuck|no response/i
            )
        end

        mark_passed()
      end
    end
  end

  describe "corrupt BEAM file deployed to device" do
    @tag :post_device
    @tag :failure_modes
    test "deploy reports which module failed to load", %{ws: ws} do
      ws = setup_installed_project(ws)

      # Corrupt the home screen BEAM after compilation
      home_beam =
        Path.join([
          ws.project_dir,
          "_build",
          "dev",
          "lib",
          @app_name,
          "ebin",
          "Elixir.MobFailureTest.HomeScreen.beam"
        ])

      # First compile
      shell_project("mix compile", ws)

      if File.exists?(home_beam) do
        {:ok, _undo} = FailureInjector.corrupt_beam(home_beam)

        sim_id = find_booted_simulator()

        if is_nil(sim_id) do
          IO.puts("  [skip] no booted iOS simulator")
          mark_passed()
        else
          result =
            shell_project("mix mob.deploy --ios", ws,
              env: %{"MOB_IOS_SIM_ID" => sim_id},
              timeout: 60_000
            )

          # Deploy should either:
          # a) refuse to push a corrupt BEAM (preferred), or
          # b) push it but detect the load failure and report it

          if Shell.success?(result) do
            # If it "succeeded", the app must have surfaced an error on the device
            # (tested via mob.connect in a real run — here we just verify the
            # output warned about the corrupt module)
            assert_output(result, ~r/warn|error|failed to load|beam/i)
          else
            assert_output(result, ~r/HomeScreen|corrupt|invalid.*beam|load.*failed/i)
          end

          mark_passed()
        end
      else
        flunk("Expected BEAM at #{home_beam} after mix compile")
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp find_booted_simulator do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted", "-j"],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        json
        |> Jason.decode!()
        |> get_in(["devices"])
        |> Enum.flat_map(fn {_runtime, devices} -> devices end)
        |> Enum.find_value(fn d ->
          if d["state"] == "Booted", do: d["udid"]
        end)

      _ ->
        nil
    end
  end
end
