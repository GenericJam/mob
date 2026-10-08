defmodule Mob.InitArgs do
  @moduledoc """
  Erlang init arguments the app chooses for its own next launch.

  The native launcher (`mob_beam.zig` on Android, `mob_beam.m` on iOS) reads
  `$MOB_DATA_DIR/mob_init_args` at startup and appends its tokens to the BEAM's
  init arguments, after the second `--` and after mob's own (`-noshell` …
  `-eval`), in development **and release** builds. This is where flags such as
  `-proto_dist` and `-ssl_dist_optfile` belong: they are init arguments, which
  the emulator rejects in the emulator-flag section that
  `beams_dir/mob_beam_flags` (written by `mix mob.deploy --beam-flags`) feeds.

      Mob.InitArgs.write(["-proto_dist", "inet_tls", "-ssl_dist_optfile", path])

  Things to know:

    * **It takes effect at the next launch.** The running BEAM already parsed
      its arguments; see `:init.get_arguments/0` for the ones this launch got.
    * **A bad argument can stop the BEAM from booting**, and then no Elixir
      code runs to undo it: only clearing the app's data or reinstalling does.
      Only write flags you understand. Distribution flags also reopen a
      network listener in release builds; authenticate and encrypt it.
    * The launcher's limits: 1023 bytes for the whole file and 63
      arguments. It keeps whole arguments up to the limit, logs, and
      drops the rest; `write/1` refuses lists over either limit instead.
    * Arguments are split on whitespace and can't be quoted, so a single
      argument can't contain a space; `write/1` refuses one that does.
    * On iOS, an argument list containing `-name` or `-sname` makes the
      launcher leave out mob's own development distribution flags (`-name`,
      `-setcookie`, the `inet_dist_*` kernel settings): the app owns
      distribution, and `mix mob.connect` won't find the node under mob's name.
      Release builds never add mob's development flags, but app arguments
      still apply and may intentionally start distribution. Android starts
      mob's development distribution at runtime (see `Mob.Dist`).
  """

  @file_name "mob_init_args"
  # Must match MOB_INIT_ARGS_BUF - 1 / MOB_INIT_ARGS_MAX in ios/mob_init_args.h
  # and buf_len - 1 / max_args in android/jni/mob_init_args.zig.
  @max_bytes 1023
  @max_args 63
  # The launcher splits on these (NUL included, so a stray one can't end the
  # list early); `write/1` also refuses the other ASCII whitespace.
  @separators [" ", "\t", "\n", "\r", <<0>>]
  @forbidden @separators ++ ["\v", "\f"]

  @type reason ::
          :no_data_dir
          | {:invalid_arg, term()}
          | {:too_many_args, non_neg_integer()}
          | {:too_large, non_neg_integer()}
          | File.posix()

  @doc """
  The file the launcher reads, or `nil` when `MOB_DATA_DIR` is unset (off
  device, where no launcher reads it).
  """
  @spec path() :: String.t() | nil
  def path do
    case System.get_env("MOB_DATA_DIR") do
      nil -> nil
      "" -> nil
      dir -> Path.join(dir, @file_name)
    end
  end

  @doc """
  The tokens currently represented by the file, or `[]` when it is absent.
  Files produced by `write/1` are exactly what the next launch receives.
  A hand-edited file beyond the documented limits may be truncated by the
  native launcher even though `read/0` returns all of its tokens.
  """
  @spec read() :: [String.t()]
  def read do
    with file when is_binary(file) <- path(),
         {:ok, contents} <- read_file(file) do
      String.split(contents, @separators, trim: true)
    else
      _ -> []
    end
  end

  @doc """
  Replaces the arguments for the next launch. `write([])` removes the file.

  Every argument must be a non-empty binary without whitespace or NUL, and the
  list must fit the launcher's limits (see the moduledoc); otherwise nothing is
  written. The file is replaced atomically, so a launch never reads half of it.
  """
  @spec write([String.t()]) :: :ok | {:error, reason()}
  def write(args) when is_list(args) do
    with file when is_binary(file) <- path() || {:error, :no_data_dir},
         {:ok, contents} <- serialize(args) do
      if contents == "", do: remove(file), else: replace(file, contents)
    end
  end

  @doc "Removes the file, so the next launch gets only mob's own arguments."
  @spec clear() :: :ok
  def clear do
    with file when is_binary(file) <- path(),
         {:error, reason} <- remove(file) do
      raise File.Error, reason: reason, action: "remove file", path: file
    else
      _ -> :ok
    end
  end

  defp serialize([]), do: {:ok, ""}

  defp serialize(args) do
    case validate_args(args) do
      {:error, _} = error ->
        error

      :ok when length(args) > @max_args ->
        {:error, {:too_many_args, length(args)}}

      :ok ->
        contents = Enum.join(args, " ") <> "\n"
        size = byte_size(contents)
        if size > @max_bytes, do: {:error, {:too_large, size}}, else: {:ok, contents}
    end
  end

  defp validate_args(args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      if valid_arg?(arg), do: {:cont, :ok}, else: {:halt, {:error, {:invalid_arg, arg}}}
    end)
  end

  defp valid_arg?(arg) when is_binary(arg) and arg != "",
    do: :binary.match(arg, @forbidden) == :nomatch

  defp valid_arg?(_), do: false

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> :absent
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: file
    end
  end

  defp replace(file, contents) do
    tmp = "#{file}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  defp remove(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end
end
