defmodule Mob.Onboarding.Workspace do
  @moduledoc """
  Creates and manages an isolated temp workspace for a single onboarding test run.

  Each workspace gets:
  - A unique directory under /tmp
  - Its own MIX_HOME, HEX_HOME, and MOB_CACHE_DIR so nothing leaks from the
    developer's real environment
  - A logs/ subdirectory where Shell output is persisted per step
  - Automatic cleanup on success; preservation on failure with a printed path

  Usage:

      ws = Workspace.create("run-A")
      # ... run tests ...
      Workspace.destroy(ws)           # call only on success
      # On failure, call nothing — workspace is preserved automatically

  The workspace struct is passed as the first argument to Shell.run/2 via
  `Workspace.shell_opts/1`, which injects the correct cd/env overrides.
  """

  defstruct [:id, :root, :project_dir, :mix_home, :hex_home, :mob_cache_dir, :logs_dir]

  @type t :: %__MODULE__{
          id: String.t(),
          root: Path.t(),
          project_dir: Path.t() | nil,
          mix_home: Path.t(),
          hex_home: Path.t(),
          mob_cache_dir: Path.t(),
          logs_dir: Path.t()
        }

  # Each test run gets its own subdirectory keyed by OS PID. This prevents
  # successive runs from reusing the same workspace paths — leftover directories
  # from a failed run would otherwise cause File.rm_rf!/mkdir_p! conflicts.
  defp base_dir, do: "/tmp/mob_onboarding/run_#{:os.getpid()}"

  @doc "Create a fresh workspace. Raises if the directory already exists."
  @spec create(String.t()) :: t()
  def create(id) do
    root = Path.join(base_dir(), id)
    if File.exists?(root), do: File.rm_rf!(root)
    File.mkdir_p!(root)

    ws = %__MODULE__{
      id: id,
      root: root,
      project_dir: nil,
      mix_home: mkdir!(root, "mix_home"),
      hex_home: mkdir!(root, "hex_home"),
      mob_cache_dir: mkdir!(root, "mob_cache"),
      logs_dir: mkdir!(root, "logs")
    }

    ws
  end

  @doc "Set the project directory once `mix mob.new` has run."
  def set_project(ws, app_name) do
    %{ws | project_dir: Path.join(ws.root, app_name)}
  end

  @doc "Delete the entire workspace. Call only on success."
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{root: root}) do
    File.rm_rf!(root)
    :ok
  end

  @doc """
  Print the workspace path and reason. Call on test failure so the developer
  can inspect logs and the generated project.
  """
  @spec preserve(t(), term()) :: :ok
  def preserve(%__MODULE__{root: root, logs_dir: logs}, reason) do
    IO.puts("""

    ══════════════════════════════════════════════════════
    Onboarding test FAILED — workspace preserved for inspection
    Path:   #{root}
    Reason: #{inspect(reason)}
    Logs:   #{logs}/
    ══════════════════════════════════════════════════════
    """)

    :ok
  end

  @doc """
  Shell options to pass to Shell.run/2 for a command that runs in the
  workspace root (e.g. `mix mob.new`).
  """
  @spec shell_opts(t(), keyword()) :: keyword()
  def shell_opts(%__MODULE__{} = ws, extra_opts \\ []) do
    extra_env = Keyword.get(extra_opts, :env, %{})
    merged_env = Map.merge(env_overrides(ws), extra_env)

    base = [
      cd: ws.root,
      env: merged_env
    ]

    Keyword.merge(base, Keyword.delete(extra_opts, :env))
  end

  @doc """
  Shell options for commands that run inside the generated project directory.
  """
  @spec project_opts(t(), keyword()) :: keyword()
  def project_opts(%__MODULE__{project_dir: nil}, _opts) do
    raise "project_dir not set — call Workspace.set_project/2 after mix mob.new"
  end

  def project_opts(%__MODULE__{} = ws, extra_opts) do
    extra_env = Keyword.get(extra_opts, :env, %{})
    merged_env = Map.merge(env_overrides(ws), extra_env)

    base = [
      cd: ws.project_dir,
      env: merged_env
    ]

    Keyword.merge(base, Keyword.delete(extra_opts, :env))
  end

  @doc "The base environment overrides that isolate this workspace from the host."
  @spec env_overrides(t()) :: map()
  def env_overrides(%__MODULE__{} = ws) do
    %{
      "MIX_HOME" => ws.mix_home,
      "HEX_HOME" => ws.hex_home,
      "MOB_CACHE_DIR" => ws.mob_cache_dir,
      # Prevent the running node from trying to connect to anything
      "MIX_ENV" => "dev",
      "RELEASE_DISTRIBUTION" => "none"
    }
  end

  @doc "Write a log entry for a step. Returns the Shell result unchanged."
  @spec log_step(t(), String.t(), term()) :: term()
  def log_step(%__MODULE__{logs_dir: logs}, step_name, result) do
    path = Path.join(logs, "#{step_name}.log")
    content = format_log(step_name, result)
    File.write!(path, content)
    result
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp mkdir!(parent, name) do
    path = Path.join(parent, name)
    File.mkdir_p!(path)
    path
  end

  defp format_log(step, %Mob.Onboarding.Shell{} = r) do
    status = if r.timed_out, do: "TIMEOUT", else: "exit #{r.exit_code}"

    """
    === #{step} [#{status}] (#{r.duration_ms}ms) ===
    Command: #{r.command}

    Output:
    #{r.output}
    """
  end

  defp format_log(step, other), do: "=== #{step} ===\n#{inspect(other)}\n"
end
