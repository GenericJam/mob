defmodule Mob.PostMortem.BeamCrashDump do
  @header_bytes 8_192

  @moduledoc """
  Scan for `erl_crash.dump` files the BEAM leaves behind, and turn each into
  a defect capsule.

  ## Why this exists

  Every BEAM node that dies hard writes a crash dump — a text file at
  `$ERL_CRASH_DUMP` if the env var is set, otherwise `erl_crash.dump` in the
  runtime's cwd. Mob apps land it in the app data directory; host tooling
  leaves them in the repo root. Nobody was collecting them until now: at
  the time this shipped, five sibling repos on the author's machine each
  had an unlooked-at dump in the root.

  A crash the framework can prove happened is a defect it can report, and
  the format from `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`
  has a `:beam_crash` kind waiting for exactly this input.

  ## Discipline

  * **Non-destructive.** The dump stays on disk. A future triager or the
    author might want the full file; deleting after emit would lose
    everything the capsule cannot fit.
  * **Idempotent.** A sha256 of the file becomes the artifact id, and the
    `Mob.PostMortem.Registry` tracks emitted ids in a public ETS table. A
    re-sweep against the same file finds it seen and does nothing.
  * **Bounded read.** A dump can be gigabytes on a busy scheduler. This
    module reads only the header window (default #{@header_bytes}) — that
    is where slogan, system version, taints and atoms count live. Anything
    beyond is by construction not on the emit path.
  * **Fingerprint stripped of concrete data.** The slogan for a
    `{badarg, ...}` from `io:put_chars/2` embeds the raw binary that was
    passed. Fingerprinting that verbatim opens one triage row per unique
    input; stripping binaries and long numeric literals groups the whole
    class into one row. See `normalize_slogan/1`.

  ## Not in scope here

  * The dump is not parsed for process state, ETS contents, or stack
    frames. A file the caller can open in `crashdump_viewer` is a better
    home for those. What ends up in the capsule is what a triager sees at
    a glance: which build, which OTP, what class of crash.
  * iOS MetricKit and Android `ApplicationExitInfo` are separate
    substrates with their own modules (`Mob.PostMortem.IOS` /
    `Mob.PostMortem.Android`) and their own follow-up tickets.
  """

  alias Mob.Defect
  alias Mob.Defect.Capsule
  alias Mob.PostMortem.Registry

  @typedoc """
  What a scanner returns for one dump file: enough to emit and to describe
  what was scanned, without the raw bytes.
  """
  @type finding :: %{
          path: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          modified_at: DateTime.t() | nil,
          slogan: String.t() | nil,
          system_version: String.t() | nil,
          taints: [String.t()],
          atoms: non_neg_integer() | nil,
          dump_version: String.t() | nil
        }

  @doc """
  Scan `paths` for `erl_crash.dump` files.

  `paths` is a list of file *or* directory paths. A directory is checked
  only for a top-level `erl_crash.dump`; this module does not recurse.
  Non-existent paths are silently skipped — a sweep from a caller that
  overshoots the possibilities should not have to guard each one.

  Returns the list of `t:finding/0` values.

  Emission is a separate step: `emit/1` takes a list of findings and
  puts anything the registry has not seen onto the defect bus. That
  split is deliberate — a caller can list findings without publishing
  them, and tests can assert on shape without touching the bus.
  """
  @spec scan([Path.t()]) :: [finding()]
  def scan(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&resolve/1)
    |> Enum.uniq()
    |> Enum.map(&scan_one/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Emit a capsule for every finding not already recorded in the registry.

  Returns the capsules emitted, in the same order.
  """
  @spec emit([finding()]) :: [Capsule.t()]
  def emit(findings) when is_list(findings) do
    Registry.start()

    for finding <- findings, Registry.mark_seen(finding.sha256) do
      Defect.emit_beam_crash(finding)
    end
  end

  @doc """
  Default paths a sweep looks at when the caller does not pass its own.

  * The value of the `ERL_CRASH_DUMP` env var, if set (that is where the
    BEAM would have written this VM's own dump).
  * The current working directory, where the BEAM writes by default.

  A caller wanting a broader sweep supplies its own list.
  """
  @spec default_paths() :: [Path.t()]
  def default_paths do
    []
    |> maybe_prepend(System.get_env("ERL_CRASH_DUMP"))
    |> Kernel.++([File.cwd!()])
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, path), do: [path | list]

  defp resolve(path) do
    cond do
      not is_binary(path) ->
        []

      not File.exists?(path) ->
        []

      File.dir?(path) ->
        candidate = Path.join(path, "erl_crash.dump")
        if File.exists?(candidate) and File.regular?(candidate), do: [candidate], else: []

      File.regular?(path) ->
        [path]

      true ->
        []
    end
  end

  defp scan_one(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, header} <- read_header(path) do
      %{
        path: path,
        sha256: sha256_of(path),
        size: stat.size,
        modified_at: posix_to_datetime(stat.mtime),
        slogan: extract(header, "Slogan:"),
        system_version: extract(header, "System version:"),
        taints: extract_list(header, "Taints:"),
        atoms: extract_integer(header, "Atoms:"),
        dump_version: extract_prefix(header, "=erl_crash_dump:")
      }
    else
      _ -> nil
    end
  end

  defp read_header(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, IO.binread(io, @header_bytes) |> normalize_binread()}
        after
          File.close(io)
        end

      other ->
        other
    end
  end

  defp normalize_binread(:eof), do: ""
  defp normalize_binread({:error, _}), do: ""
  defp normalize_binread(data) when is_binary(data), do: data

  defp sha256_of(path) do
    hash =
      path
      # 64K matches BEAM's idiomatic chunk size and cuts reduce-count
      # by 16x vs the previous 4K on a multi-GB dump. Not a
      # correctness concern; a "surprised-by-latency" concern.
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    "sha256:" <> hash
  end

  defp posix_to_datetime(mtime) when is_integer(mtime),
    do: DateTime.from_unix!(mtime)

  defp posix_to_datetime(_), do: nil

  # Header field extraction — a dump's first ~10 lines are all "Key: value"
  # pairs. The value can carry a comma-separated list (Taints), an integer
  # (Atoms), or a free-form string that spans one line. Anything more
  # structured than that lives past the header and is out of scope here.

  defp extract(header, key) do
    case Regex.run(~r/^#{Regex.escape(key)}\s*(.*?)$/m, header, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_list(header, key) do
    case extract(header, key) do
      nil ->
        []

      "" ->
        []

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp extract_integer(header, key) do
    case extract(header, key) do
      nil -> nil
      value -> parse_integer(value)
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp extract_prefix(header, prefix) do
    case Regex.run(~r/^#{Regex.escape(prefix)}(\S+)/m, header, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  @doc """
  A version of the slogan with concrete data stripped, for the fingerprint.

  A raw slogan from a `{badarg, ...}` on `io:put_chars/2` looks like

      Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,[<<42,42,...4KB more...>>]]}]})

  and the binary embedded there varies per crash. Two crashes for the same
  root cause thus fingerprint differently, which is exactly the shattering
  the bus is meant to prevent (see the "fingerprint and evidence are
  separate" decision record).

  Strip:

  * Binary literals `<<...>>` — replaced by `<<>>`
  * Long numeric sequences (>= 8 digits with commas or dots between them)
    that look like the printable form of the same — replaced by `<<>>`
  * Runs of whitespace collapsed

  What survives: atom-shaped tokens, module and function names, arities,
  the structural punctuation. That is what identifies the *class* of
  crash, which is what a fingerprint is for.
  """
  @spec normalize_slogan(String.t() | nil) :: String.t() | nil
  def normalize_slogan(nil), do: nil

  def normalize_slogan(slogan) when is_binary(slogan) do
    slogan
    # `<<...>>` or `<<...` at end-of-string — the header read is bounded
    # (see @header_bytes), and a big embedded binary can be cut off with
    # no closing `>>`. Without the `|$` branch the truncated payload
    # bytes survive into the fingerprint and shatter classes by the
    # exact bytes that happened to fit — the shattering we exist to
    # prevent. `(?s)` so `.` crosses newlines (a slogan spanning lines
    # cut off mid-binary would otherwise stop at the first newline
    # inside the literal).
    |> String.replace(~r/<<(?s:[^>]*)(?:>>|$)/, "<<>>")
    # A comma/dot/space-separated numeric run of ≥8 digits is the
    # printable form of the same binary payload (`[104,101,108,...]`),
    # which the platform sometimes prints instead of `<<>>`. Not a
    # perfect discriminator — a version like `28.0.20260803` matches,
    # and so does an epoch millisecond timestamp. Effect is *class
    # collapse* (two versions become the same fingerprint), not
    # *shattering* — acceptable, but documented.
    |> String.replace(~r/(?:\d[,.\s]?){8,}\d?/, "<<>>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
