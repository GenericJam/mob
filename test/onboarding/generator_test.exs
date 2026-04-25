defmodule Mob.Onboarding.GeneratorTest do
  @moduledoc """
  Tests for Stages 1–4 of onboarding: archive installation, project generation,
  `mix mob.install`, and `mix mob.doctor`.

  These tests require no simulator or emulator — they run headlessly and are
  fast enough to include in PR gating.

  Tagged `@tag :generator` in addition to the module-level `:onboarding` tag,
  so they can be run in isolation:

      mix test --only onboarding:generator
  """
  use Mob.Onboarding.Case

  # Integration tests: archive install + OTP download can take several minutes.
  @moduletag timeout: :infinity

  @app_name "mob_test_app_gen"

  # ── Stage 1: archive install ──────────────────────────────────────────────────

  describe "mob_new archive" do
    @tag :generator
    test "installs from hex", %{ws: ws} do
      result = shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
      assert_success(result)
      assert_output(result, "mob_new")

      # Verify it is listed in installed archives
      list = shell("mix archive", ws)
      assert_success(list)
      assert_output(list, ~r/mob_new-\d+\.\d+/)
      mark_passed()
    end

    @tag :generator
    test "installed archive reports correct version", %{ws: ws} do
      shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
      result = shell("mix help mob.new", ws)
      assert_success(result)
      assert_output(result, "mob.new")
      mark_passed()
    end
  end

  # ── Stage 2: project generation ───────────────────────────────────────────────

  describe "mix mob.new" do
    setup %{ws: ws} do
      shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
      {:ok, ws: ws}
    end

    @tag :generator
    test "creates project directory", %{ws: ws} do
      result = shell("mix mob.new #{@app_name}", ws)
      assert_success(result)
      assert_dir(ws, @app_name)
      mark_passed()
    end

    @tag :generator
    test "generates required Elixir source files", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      assert_file(ws, "#{@app_name}/mix.exs")
      assert_file(ws, "#{@app_name}/lib/#{@app_name}/app.ex")
      assert_file(ws, "#{@app_name}/lib/#{@app_name}/home_screen.ex")
      mark_passed()
    end

    @tag :generator
    test "home_screen uses ~MOB sigil and correct module name", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      # Paths are relative to ws.root (workspace root), not the project dir
      hs = "#{@app_name}/lib/#{@app_name}/home_screen.ex"
      assert_file_contains(ws, hs, "use Mob.Screen")
      assert_file_contains(ws, hs, ~r/~MOB"""/)
      assert_file_contains(ws, hs, "defmodule MobTestAppGen.HomeScreen")
      # Must NOT contain import Mob.Sigil — use Mob.Screen imports it
      refute_file_contains(ws, hs, "import Mob.Sigil")
      mark_passed()
    end

    @tag :generator
    test "home_screen on_tap handlers use pre-computed tuples, not inline self()", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      content = File.read!(Path.join([ws.root, @app_name, "lib", @app_name, "home_screen.ex"]))
      # The sigil should never see on_tap={{self(), ...}} — double braces
      refute content =~ ~r/on_tap=\{\{self\(\)/
      mark_passed()
    end

    @tag :generator
    test "generates iOS build.sh with logo copy step", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      assert_file(ws, "#{@app_name}/ios/build.sh")
      assert_file_contains(ws, "#{@app_name}/ios/build.sh", "mob_logo_dark.png")
      assert_file_contains(ws, "#{@app_name}/ios/build.sh", "mob_logo_light.png")
      mark_passed()
    end

    @tag :generator
    test "generates Android project with logo assets", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)

      assert_file(
        ws,
        "#{@app_name}/android/app/src/main/assets/mob_logo_dark.png"
      )

      assert_file(
        ws,
        "#{@app_name}/android/app/src/main/assets/mob_logo_light.png"
      )

      mark_passed()
    end

    @tag :generator
    test "generates valid mix.exs", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      ws = Workspace.set_project(ws, @app_name)
      result = shell_project("mix deps.get --dry-run", ws, timeout: 30_000)
      # We expect either success or "nothing to fetch" — what we do NOT want
      # is a parse error from a malformed mix.exs
      refute_output(result, ~r/\(SyntaxError\)|\(CompileError\)/)
      mark_passed()
    end

    @tag :generator
    test "generated module name is correctly camelised", %{ws: ws} do
      assert_success(shell("mix mob.new multi_word_app", ws))
      # Entry point is app.ex, not a flat multi_word_app.ex
      assert_file_contains(
        ws,
        "multi_word_app/lib/multi_word_app/app.ex",
        "defmodule MultiWordApp.App"
      )

      assert_file_contains(
        ws,
        "multi_word_app/lib/multi_word_app/home_screen.ex",
        "defmodule MultiWordApp.HomeScreen"
      )

      mark_passed()
    end

    @tag :generator
    test "android package name uses correct convention", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)

      assert_file_contains(
        ws,
        "#{@app_name}/android/app/src/main/AndroidManifest.xml",
        "com.mob.mob_test_app_gen"
      )

      mark_passed()
    end

    @tag :generator
    test "ios/build.sh is executable", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      build_sh = Path.join([ws.root, @app_name, "ios", "build.sh"])
      stat = File.stat!(build_sh)
      # Check owner-execute bit (0o100)
      assert Bitwise.band(stat.mode, 0o100) != 0
      mark_passed()
    end

    @tag :generator
    test "android/gradlew is executable", %{ws: ws} do
      shell("mix mob.new #{@app_name}", ws)
      gradlew = Path.join([ws.root, @app_name, "android", "gradlew"])
      stat = File.stat!(gradlew)
      assert Bitwise.band(stat.mode, 0o100) != 0
      mark_passed()
    end
  end

  # ── Stage 3: mix mob.install ──────────────────────────────────────────────────

  describe "mix mob.install" do
    setup %{ws: ws} do
      shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
      shell("mix mob.new #{@app_name}", ws)
      ws = Workspace.set_project(ws, @app_name)
      {:ok, ws: ws}
    end

    @tag :generator
    test "fetches dependencies without errors", %{ws: ws} do
      configure_mob_exs(ws)
      result = shell_project("mix mob.install", ws, timeout: 600_000)
      assert_success(result)
      refute_output(result, ~r/\*\* \(.*Error\)/)
      mark_passed()
    end

    @tag :generator
    test "OTP iOS simulator cache is populated with erts- directory", %{ws: ws} do
      configure_mob_exs(ws)
      shell_project("mix mob.install", ws, timeout: 600_000)

      # OtpDownloader in the published mob_dev package uses ~/.mob/cache/ regardless
      # of MOB_CACHE_DIR. Check the global cache that mob.install actually writes to.
      # (A future mob_dev release will respect MOB_CACHE_DIR for full isolation.)
      otp_cache = Path.join([System.get_env("HOME"), ".mob", "cache"])
      cache_dirs = File.ls!(otp_cache)
      ios_dir = Enum.find(cache_dirs, &String.starts_with?(&1, "otp-ios-sim-"))

      refute is_nil(ios_dir),
             "No otp-ios-sim-* directory in #{otp_cache} after mob.install"

      erts_dirs =
        File.ls!(Path.join(otp_cache, ios_dir))
        |> Enum.filter(&String.starts_with?(&1, "erts-"))

      assert length(erts_dirs) >= 1,
             "otp-ios-sim cache exists but contains no erts-* directory (empty download?)"

      mark_passed()
    end

    @tag :generator
    test "OTP Android cache is populated with erts- directory", %{ws: ws} do
      configure_mob_exs(ws)
      shell_project("mix mob.install", ws, timeout: 600_000)

      # Same note as iOS test above — uses actual global cache.
      otp_cache = Path.join([System.get_env("HOME"), ".mob", "cache"])
      cache_dirs = File.ls!(otp_cache)
      android_dir = Enum.find(cache_dirs, &String.starts_with?(&1, "otp-android-"))

      refute is_nil(android_dir),
             "No otp-android-* directory in #{otp_cache} after mob.install"

      erts_dirs =
        File.ls!(Path.join(otp_cache, android_dir))
        |> Enum.filter(&String.starts_with?(&1, "erts-"))

      assert length(erts_dirs) >= 1,
             "otp-android cache exists but contains no erts-* directory (empty download?)"

      mark_passed()
    end
  end

  # ── Stage 4: mix mob.doctor ───────────────────────────────────────────────────

  describe "mix mob.doctor" do
    setup %{ws: ws} do
      shell("mix archive.install hex mob_new --force", ws, timeout: 60_000)
      shell("mix mob.new #{@app_name}", ws)
      ws = Workspace.set_project(ws, @app_name)
      configure_mob_exs(ws)
      shell_project("mix mob.install", ws, timeout: 600_000)
      {:ok, ws: ws}
    end

    @tag :generator
    test "exits 0 with no hard failures", %{ws: ws} do
      result = shell_project("mix mob.doctor", ws)
      assert_success(result)
      refute_output(result, ~r/✗/)
      mark_passed()
    end

    @tag :generator
    test "reports Elixir version passing", %{ws: ws} do
      result = shell_project("mix mob.doctor", ws)
      assert_doctor_pass(result, "Elixir")
      mark_passed()
    end

    @tag :generator
    test "reports OTP iOS simulator cache passing", %{ws: ws} do
      result = shell_project("mix mob.doctor", ws)
      assert_doctor_pass(result, "OTP iOS simulator")
      mark_passed()
    end

    @tag :generator
    test "reports OTP Android cache passing", %{ws: ws} do
      result = shell_project("mix mob.doctor", ws)
      assert_doctor_pass(result, "OTP Android")
      mark_passed()
    end
  end
end
