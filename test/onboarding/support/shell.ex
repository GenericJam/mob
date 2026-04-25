defmodule Mob.Onboarding.Shell do
  @moduledoc """
  Execute shell commands in an isolated environment with captured output,
  timeout enforcement, and structured error reporting.
  """

  @default_timeout_ms 120_000

  defstruct [:command, :exit_code, :output, :duration_ms, :timed_out]

  @type result :: %__MODULE__{
          command: String.t(),
          exit_code: non_neg_integer() | :timeout,
          output: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean()
        }

  @doc """
  Run a shell command. Returns a `%Shell{}` result struct.

  Options:
  - `:cd`      — working directory (required for most onboarding steps)
  - `:env`     — map of extra env vars to merge into the isolated env
  - `:timeout` — ms before the process is killed (default 120_000)
  - `:echo`    — if true, stream output to test stdout as it arrives (default false)
  """
  @spec run(String.t(), keyword()) :: result()
  def run(command, opts \\ []) do
    cd = Keyword.get(opts, :cd, System.tmp_dir!())
    extra = Keyword.get(opts, :env, %{})
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    echo = Keyword.get(opts, :echo, false)

    env = build_env(extra) |> to_charlist_pairs()
    t0 = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn, "/bin/sh -c #{shell_escape(command)}"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cd},
        {:env, env}
      ])

    {output, exit_code, timed_out} = collect(port, "", timeout, echo)
    duration_ms = System.monotonic_time(:millisecond) - t0

    %__MODULE__{
      command: command,
      exit_code: exit_code,
      output: output,
      duration_ms: duration_ms,
      timed_out: timed_out
    }
  end

  @doc "Returns true iff the command exited 0."
  def success?(%__MODULE__{exit_code: 0}), do: true
  def success?(%__MODULE__{}), do: false

  @doc "Raises a descriptive error if the command did not exit 0."
  def assert_success!(%__MODULE__{exit_code: 0} = r), do: r

  def assert_success!(%__MODULE__{timed_out: true} = r) do
    raise """
    Command timed out after #{r.duration_ms}ms:
      #{r.command}

    Output so far:
    #{indent(r.output)}
    """
  end

  def assert_success!(%__MODULE__{} = r) do
    raise """
    Command exited #{r.exit_code} (#{r.duration_ms}ms):
      #{r.command}

    Output:
    #{indent(r.output)}
    """
  end

  @doc "Returns true iff the output contains the given string or matches the regex."
  def output_contains?(%__MODULE__{output: out}, %Regex{} = re), do: out =~ re

  def output_contains?(%__MODULE__{output: out}, str) when is_binary(str),
    do: String.contains?(out, str)

  # ── Private ───────────────────────────────────────────────────────────────────

  defp collect(port, acc, timeout, echo) do
    receive do
      {^port, {:data, data}} ->
        if echo, do: IO.write(data)
        collect(port, acc <> data, timeout, echo)

      {^port, {:exit_status, code}} ->
        {acc, code, false}
    after
      timeout ->
        Port.close(port)
        {acc, :timeout, true}
    end
  end

  # Minimal but non-empty environment. Inherits PATH from the host so tools
  # installed by mise/asdf/nix remain visible, but MIX_HOME / HEX_HOME are
  # always overridden by the workspace-specific values in `extra`.
  defp build_env(extra) do
    base = %{
      "HOME" => System.get_env("HOME", "/tmp"),
      "PATH" => System.get_env("PATH", "/usr/bin:/bin"),
      "LANG" => "en_US.UTF-8",
      "LC_ALL" => "en_US.UTF-8",
      "TERM" => "dumb",
      # Prevent IEx from trying to start interactive sessions
      "MIX_ENV" => "dev"
    }

    # Strip vars that leak host toolchain state
    strip = ~w[MIX_HOME HEX_HOME ERL_LIBS ELIXIR_ERL_OPTIONS]
    filtered = Enum.reduce(strip, System.get_env(), &Map.delete(&2, &1))

    filtered
    |> Map.merge(base)
    |> Map.merge(extra)
  end

  defp to_charlist_pairs(map) do
    Enum.map(map, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp shell_escape(cmd), do: "'#{String.replace(cmd, "'", "'\\''")}'"

  defp indent(str) do
    str
    |> String.split("\n")
    |> Enum.map(&("  " <> &1))
    |> Enum.join("\n")
  end
end
