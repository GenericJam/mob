defmodule Mob.Onboarding.FailureInjector do
  @moduledoc """
  Helpers that inject specific failure conditions into a workspace or project
  so we can assert that the framework surfaces a useful error message rather
  than crashing silently.

  Each injection function returns `{:ok, undo_fn}` where `undo_fn/0` reverses
  the injection. For irreversible changes (like writing to a temp dir that will
  be destroyed), `undo_fn` is a no-op.
  """

  alias Mob.Onboarding.Workspace

  @type undo_fn :: (-> :ok)

  # ── OTP download failures ─────────────────────────────────────────────────────

  @doc """
  Create the OTP cache directory but leave it empty, as happens when the Nix
  curl silently fails but `File.mkdir_p!` has already been called.

  The next `mix mob.install` should detect the empty dir, delete it, and
  re-download — or surface a clear error if it cannot.
  """
  @spec empty_otp_cache(Workspace.t(), :ios | :android) :: {:ok, undo_fn()}
  def empty_otp_cache(%Workspace{mob_cache_dir: cache}, platform) do
    # Match the naming pattern used by OtpDownloader
    prefix =
      case platform do
        :ios -> "otp-ios-sim-"
        :android -> "otp-android-"
      end

    # Create a plausible-looking but empty cache dir
    fake_dir = Path.join(cache, "#{prefix}73ba6e0f")
    File.mkdir_p!(fake_dir)

    undo = fn ->
      File.rm_rf!(fake_dir)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Point the OTP download URL to an unreachable host so the download fails
  with a connection error. Sets MOB_OTP_BASE_URL in the env overrides.

  Returns `{:ok, env_patch}` — merge `env_patch` into your Shell.run/2 env.
  """
  @spec bad_download_url() :: {:ok, map()}
  def bad_download_url do
    # Port 1 is almost never open; connection should be refused immediately
    {:ok, %{"MOB_OTP_BASE_URL" => "http://127.0.0.1:1/nonexistent"}}
  end

  # ── Toolchain failures ────────────────────────────────────────────────────────

  @doc """
  Prepend a fake `elixir` script to PATH that reports a version below the
  minimum. Useful for testing `mix mob.doctor` version checks.

  Returns `{:ok, env_patch}` — merge into Shell env.
  """
  @spec fake_old_elixir(Workspace.t(), String.t()) :: {:ok, map()}
  def fake_old_elixir(%Workspace{root: root}, version \\ "1.16.0") do
    bin_dir = Path.join(root, "fake_bin")
    File.mkdir_p!(bin_dir)

    # Fake `elixir` that just echoes the scripted version
    fake_elixir = Path.join(bin_dir, "elixir")

    File.write!(fake_elixir, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "Erlang/OTP 27 [erts-16.0] [64-bit]"
      echo "Elixir #{version} (compiled with Erlang/OTP 27)"
      exit 0
    fi
    # Fall through to real elixir for everything else (so mix still works)
    exec "$(which -a elixir | grep -v #{bin_dir} | head -1)" "$@"
    """)

    File.chmod!(fake_elixir, 0o755)

    fake_mix = Path.join(bin_dir, "mix")

    File.write!(fake_mix, """
    #!/bin/sh
    exec "$(which -a mix | grep -v #{bin_dir} | head -1)" "$@"
    """)

    File.chmod!(fake_mix, 0o755)

    env_patch = %{"PATH" => "#{bin_dir}:#{System.get_env("PATH")}"}
    {:ok, env_patch}
  end

  @doc """
  Hide a specific tool (adb, xcrun, java, etc.) from PATH by removing all
  directories that contain the real executable from the PATH env var.

  This makes `System.find_executable(tool)` return nil in the subprocess,
  which triggers mob.doctor's "missing tool" failure path rather than the
  "found but broken" path.

  Returns `{:ok, env_patch}` — merge into Shell env.
  """
  @spec hide_tool(Workspace.t(), String.t()) :: {:ok, map()}
  def hide_tool(%Workspace{}, tool) do
    filtered_path =
      (System.get_env("PATH") || "")
      |> String.split(":")
      |> Enum.reject(fn dir ->
        path = Path.join(dir, tool)

        case File.stat(path) do
          {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
          _ -> false
        end
      end)
      |> Enum.join(":")

    {:ok, %{"PATH" => filtered_path}}
  end

  # ── Project-level failures ────────────────────────────────────────────────────

  @doc """
  Corrupt a compiled BEAM file by overwriting it with garbage bytes.
  Simulates a partially-written or mis-transferred BEAM arriving at the device.

  `module_path` is the path to the .beam file, e.g.
  `"_build/dev/lib/my_app/ebin/Elixir.MyApp.HomeScreen.beam"`.

  Returns `{:ok, undo_fn}` — call undo to restore the original.
  """
  @spec corrupt_beam(Path.t()) :: {:ok, undo_fn()}
  def corrupt_beam(module_path) do
    backup = module_path <> ".bak"
    File.copy!(module_path, backup)
    File.write!(module_path, "NOTBEAM garbage bytes \x00\xFF\x00")

    undo = fn ->
      File.copy!(backup, module_path)
      File.rm!(backup)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Write a stale (non-existent) `elixir_lib` path into mob.exs — replicates
  the Nix upgrade failure where the Nix store path changes between versions.
  """
  @spec stale_elixir_lib(Workspace.t()) :: {:ok, undo_fn()}
  def stale_elixir_lib(%Workspace{project_dir: project_dir}) when not is_nil(project_dir) do
    mob_exs = Path.join(project_dir, "mob.exs")
    original = File.read!(mob_exs)

    patched =
      original <>
        """

        # Injected by FailureInjector — stale path
        config :mob_dev, elixir_lib: "/nix/store/aaaaaaaaaaaaaaaa-elixir-1.17.0/lib"
        """

    File.write!(mob_exs, patched)

    undo = fn ->
      File.write!(mob_exs, original)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Write a stale (non-existent) `mob_dir` path into mob.exs, replicating what
  happens when the mob library directory moves (e.g. after a version upgrade
  or checkout into a different path). `mix mob.doctor` validates mob_dir and
  will report ✗ mob_dir when it no longer exists.
  """
  @spec stale_mob_dir(Workspace.t()) :: {:ok, undo_fn()}
  def stale_mob_dir(%Workspace{project_dir: project_dir}) when not is_nil(project_dir) do
    mob_exs = Path.join(project_dir, "mob.exs")
    original = File.read!(mob_exs)

    patched =
      Regex.replace(~r/mob_dir: "[^"]*"/, original, "mob_dir: \"/nonexistent/moved/mob-old\"")

    File.write!(mob_exs, patched)

    undo = fn ->
      File.write!(mob_exs, original)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Inject a `Process.sleep(:infinity)` into `mount/3` of the home screen,
  simulating a screen that starts but never renders — causing the app to hang
  on a blank screen.
  """
  @spec inject_mount_hang(Workspace.t()) :: {:ok, undo_fn()}
  def inject_mount_hang(%Workspace{project_dir: project_dir}) do
    home = Path.join([project_dir, "lib", project_name(project_dir), "home_screen.ex"])
    original = File.read!(home)

    patched =
      String.replace(
        original,
        "def mount(_params, _session, socket) do",
        "def mount(_params, _session, socket) do\n    Process.sleep(:infinity)"
      )

    File.write!(home, patched)

    undo = fn ->
      File.write!(home, original)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Inject a syntax error into a module, simulating a hot-push where the
  developer has a compile error in their code.
  """
  @spec inject_compile_error(Workspace.t(), :home_screen) :: {:ok, undo_fn()}
  def inject_compile_error(%Workspace{project_dir: project_dir}, :home_screen) do
    home = Path.join([project_dir, "lib", project_name(project_dir), "home_screen.ex"])
    original = File.read!(home)
    # Append something that will definitely not compile
    patched = original <> "\n  def this_is a syntax error !!! do\nend\n"
    File.write!(home, patched)

    undo = fn ->
      File.write!(home, original)
      :ok
    end

    {:ok, undo}
  end

  @doc """
  Remove the `Mob.Dist.ensure_started/1` call from the application, so the
  device BEAM starts but never joins the distribution network. This tests that
  `mix mob.connect` times out with a clear message rather than hanging forever.
  """
  @spec remove_dist_start(Workspace.t()) :: {:ok, undo_fn()}
  def remove_dist_start(%Workspace{project_dir: project_dir}) do
    # Generator creates lib/app_name/app.ex (not lib/app_name.ex)
    app_name = project_name(project_dir)
    app_file = Path.join([project_dir, "lib", app_name, "app.ex"])
    original = File.read!(app_file)
    patched = Regex.replace(~r/Mob\.Dist\.ensure_started\([^)]+\)\n?/, original, "")
    File.write!(app_file, patched)

    undo = fn ->
      File.write!(app_file, original)
      :ok
    end

    {:ok, undo}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp project_name(project_dir), do: Path.basename(project_dir)
end
